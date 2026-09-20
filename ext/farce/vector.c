#include "containers.h"
#include "ruby/io.h"

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#define VECTOR_INITIAL_CAPACITY 16
static VALUE cVector;

typedef struct vector_waiter vector_waiter_t;

struct vector_waiter {
    int read_fd;
    int write_fd;
    bool notified;
    vector_waiter_t *next;
};

typedef struct {
    pthread_mutex_t lock;
    VALUE *values;
    size_t capacity;
    size_t size;
    vector_waiter_t *waiters;
    uint64_t generation;
    bool compare_by_identity;
    bool updating;
    bool initialized;
} vector_t;

typedef struct {
    bool finite;
    double deadline;
} vector_timeout_t;

static void
vector_mark(void *pointer)
{
    vector_t *vector = pointer;
    if (!vector->values) return;
    for (size_t index = 0; index < vector->size; index++) {
        rb_gc_mark_movable(vector->values[index]);
    }
}

static void
vector_compact(void *pointer)
{
    vector_t *vector = pointer;
    if (!vector->values) return;
    for (size_t index = 0; index < vector->size; index++) {
        vector->values[index] = rb_gc_location(vector->values[index]);
    }
}

static void
vector_free(void *pointer)
{
    vector_t *vector = pointer;
    pthread_mutex_destroy(&vector->lock);
    free(vector->values);
    ruby_xfree(vector);
}

static size_t
vector_memsize(const void *pointer)
{
    const vector_t *vector = pointer;
    return vector ? sizeof(vector_t) + vector->capacity * sizeof(VALUE) : 0;
}

static const rb_data_type_t vector_type = {
    .wrap_struct_name = "Ractor::Containers::Vector",
    .function = {
        .dmark = vector_mark,
        .dfree = vector_free,
        .dsize = vector_memsize,
        .dcompact = vector_compact,
    },
    .flags = RUBY_TYPED_FROZEN_SHAREABLE,
};

static VALUE
vector_allocate(VALUE klass)
{
    vector_t *vector;
    VALUE object = TypedData_Make_Struct(klass, vector_t, &vector_type, vector);
    pthread_mutex_init(&vector->lock, NULL);
    vector->values = NULL;
    vector->capacity = 0;
    vector->size = 0;
    vector->waiters = NULL;
    vector->generation = 0;
    vector->compare_by_identity = false;
    vector->updating = false;
    vector->initialized = false;
    return object;
}

static vector_t *
get_vector(VALUE self)
{
    vector_t *vector;
    TypedData_Get_Struct(self, vector_t, &vector_type, vector);
    if (!vector->initialized) rb_raise(rb_eRuntimeError, "uninitialized Vector");
    return vector;
}

static VALUE *
vector_allocate_values(size_t capacity)
{
    if (capacity > SIZE_MAX / sizeof(VALUE)) return NULL;
    VALUE *values = malloc(capacity * sizeof(VALUE));
    if (!values) return NULL;
    for (size_t index = 0; index < capacity; index++) values[index] = Qnil;
    return values;
}

static bool
vector_ensure_capacity(vector_t *vector, size_t required)
{
    if (required <= vector->capacity) return true;

    size_t capacity = vector->capacity ? vector->capacity : VECTOR_INITIAL_CAPACITY;
    while (capacity < required) {
        if (capacity > SIZE_MAX / 2) {
            capacity = required;
            break;
        }
        capacity *= 2;
    }

    VALUE *values = vector_allocate_values(capacity);
    if (!values) return false;
    for (size_t index = 0; index < vector->size; index++) values[index] = vector->values[index];
    free(vector->values);
    vector->values = values;
    vector->capacity = capacity;
    return true;
}

static double
vector_monotonic_now(void)
{
    struct timespec now;
#ifdef CLOCK_MONOTONIC
    if (clock_gettime(CLOCK_MONOTONIC, &now) == 0) {
        return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
    }
#endif
    struct timeval fallback;
    gettimeofday(&fallback, NULL);
    return (double)fallback.tv_sec + (double)fallback.tv_usec / 1000000.0;
}

static vector_timeout_t
vector_parse_timeout(VALUE value)
{
    vector_timeout_t timeout = {.finite = false, .deadline = 0};
    if (NIL_P(value)) return timeout;

    double seconds = NUM2DBL(value);
    if (!isfinite(seconds) || seconds < 0) {
        rb_raise(rb_eArgError, "timeout must be a finite, non-negative number or nil");
    }
    timeout.finite = true;
    timeout.deadline = vector_monotonic_now() + seconds;
    return timeout;
}

static VALUE
vector_timeout_keyword(VALUE keywords)
{
    VALUE timeout = Qnil;
    if (!NIL_P(keywords)) {
        ID keyword_ids[] = {rb_intern("timeout")};
        VALUE keyword_values[1];
        rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);
        if (keyword_values[0] != Qundef) timeout = keyword_values[0];
    }
    return timeout;
}

static void
vector_set_fd_flags(int fd)
{
#ifdef _WIN32
    (void)fd;
#else
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) (void)fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    flags = fcntl(fd, F_GETFD, 0);
    if (flags >= 0) (void)fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
#endif
}

/* Called with vector->lock held. Each waiter has an independent pipe, so a
 * transition wakes every waiting thread or scheduled fiber. */
static void
vector_notify_waiters_locked(vector_t *vector)
{
    unsigned char byte = 1;
    vector->generation++;
    for (vector_waiter_t *waiter = vector->waiters; waiter; waiter = waiter->next) {
        if (waiter->notified) continue;
        ssize_t result;
        do {
            result = write(waiter->write_fd, &byte, 1);
        } while (result < 0 && errno == EINTR);
        if (result == 1 || (result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))) {
            waiter->notified = true;
        }
    }
}

static void
vector_finish_update_locked(vector_t *vector)
{
    vector->updating = false;
    vector_notify_waiters_locked(vector);
}

typedef struct {
    vector_t *vector;
    vector_waiter_t waiter;
    vector_timeout_t *timeout;
} vector_wait_context_t;

static bool
vector_wait_for_descriptor(int fd, vector_timeout_t *timeout)
{
    VALUE wait_timeout = Qnil;
    if (timeout->finite) {
        double remaining = timeout->deadline - vector_monotonic_now();
        if (remaining <= 0) return false;
        wait_timeout = DBL2NUM(remaining);
    }
    return containers_wait_for_readable(fd, wait_timeout);
}

static VALUE
vector_wait_body(VALUE opaque)
{
    vector_wait_context_t *context = (vector_wait_context_t *)opaque;
    return vector_wait_for_descriptor(context->waiter.read_fd, context->timeout) ? Qtrue : Qfalse;
}

static VALUE
vector_wait_cleanup(VALUE opaque)
{
    vector_wait_context_t *context = (vector_wait_context_t *)opaque;
    vector_waiter_t **link;

    pthread_mutex_lock(&context->vector->lock);
    for (link = &context->vector->waiters; *link; link = &(*link)->next) {
        if (*link == &context->waiter) {
            *link = context->waiter.next;
            break;
        }
    }
    pthread_mutex_unlock(&context->vector->lock);
    close(context->waiter.read_fd);
    close(context->waiter.write_fd);
    return Qnil;
}

/* Called with vector->lock held and always returns with it released. The
 * waiter is registered before unlocking, which closes the check-to-wait race
 * without requiring a permanent descriptor on every Vector. */
static bool
vector_wait_once(vector_t *vector, vector_timeout_t *timeout)
{
    int descriptors[2];
    if (pipe(descriptors) != 0) {
        pthread_mutex_unlock(&vector->lock);
        rb_sys_fail("pipe");
    }
    vector_set_fd_flags(descriptors[0]);
    vector_set_fd_flags(descriptors[1]);

    vector_wait_context_t context = {
        .vector = vector,
        .waiter = {
            .read_fd = descriptors[0],
            .write_fd = descriptors[1],
            .notified = false,
            .next = vector->waiters,
        },
        .timeout = timeout,
    };
    vector->waiters = &context.waiter;
    pthread_mutex_unlock(&vector->lock);
    return RTEST(rb_ensure(vector_wait_body, (VALUE)&context, vector_wait_cleanup, (VALUE)&context));
}

/* Returns with vector->lock held on success and released on timeout. */
static bool
vector_lock_for_update(vector_t *vector, vector_timeout_t *timeout)
{
    for (;;) {
        pthread_mutex_lock(&vector->lock);
        if (!vector->updating) return true;
        if (!vector_wait_once(vector, timeout)) return false;
    }
}

static long long
vector_convert_index(VALUE value)
{
    return NUM2LL(value);
}

static bool
vector_lookup_index(vector_t *vector, long long raw, size_t *index)
{
    if (raw < 0) {
        unsigned long long distance = (unsigned long long)(-(raw + 1)) + 1;
        if (distance > vector->size) return false;
        *index = vector->size - (size_t)distance;
        return true;
    }
    if ((unsigned long long)raw >= vector->size) return false;
    *index = (size_t)raw;
    return true;
}

/* Called with the lock held. Raises only after releasing it. */
static size_t
vector_assignment_index(vector_t *vector, long long raw)
{
    if (raw < 0) {
        unsigned long long distance = (unsigned long long)(-(raw + 1)) + 1;
        if (distance > vector->size) {
            pthread_mutex_unlock(&vector->lock);
            rb_raise(rb_eIndexError, "index %lld too small for vector; minimum: -%zu", raw, vector->size);
        }
        return vector->size - (size_t)distance;
    }
    if ((unsigned long long)raw >= SIZE_MAX) {
        pthread_mutex_unlock(&vector->lock);
        rb_raise(rb_eIndexError, "index %lld too large", raw);
    }
    return (size_t)raw;
}

static VALUE
vector_initialize(int argc, VALUE *argv, VALUE self)
{
    VALUE source = Qnil;
    VALUE keywords = Qnil;
    VALUE identity = Qundef;
    ID keyword_ids[] = {rb_intern("compare_by_identity")};
    VALUE keyword_values[1];
    vector_t *vector;

    rb_scan_args(argc, argv, "01:", &source, &keywords);
    if (!NIL_P(keywords)) {
        rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);
        identity = keyword_values[0];
    }
    TypedData_Get_Struct(self, vector_t, &vector_type, vector);
    if (vector->initialized) rb_raise(rb_eRuntimeError, "Vector is already initialized");

    vector->compare_by_identity = identity == Qundef
        ? false
        : containers_strict_bool(identity, "compare_by_identity");

    size_t size = 0;
    if (!NIL_P(source)) {
        Check_Type(source, T_ARRAY);
        size = (size_t)RARRAY_LEN(source);
    }
    size_t capacity = size > VECTOR_INITIAL_CAPACITY ? size : VECTOR_INITIAL_CAPACITY;
    vector->values = vector_allocate_values(capacity);
    if (!vector->values) rb_memerror();
    vector->capacity = capacity;

    for (size_t index = 0; index < size; index++) {
        VALUE value = RARRAY_AREF(source, (long)index);
        containers_check_shareable(value);
        vector->values[index] = value;
    }
    vector->size = size;
    vector->initialized = true;
    containers_finish_initialization(self);
    return self;
}

static VALUE
vector_snapshot_locked(VALUE self)
{
    vector_t *vector = get_vector(self);
    return rb_ary_new_from_values((long)vector->size, vector->values);
}

static VALUE
vector_snapshot_unlock(VALUE self)
{
    pthread_mutex_unlock(&get_vector(self)->lock);
    return Qnil;
}

static VALUE
vector_snapshot(VALUE self)
{
    pthread_mutex_lock(&get_vector(self)->lock);
    return rb_ensure(vector_snapshot_locked, self, vector_snapshot_unlock, self);
}

static VALUE
vector_size(VALUE self)
{
    vector_t *vector = get_vector(self);
    size_t size;
    pthread_mutex_lock(&vector->lock);
    size = vector->size;
    pthread_mutex_unlock(&vector->lock);
    return SIZET2NUM(size);
}

static VALUE
vector_compare_by_identity_p(VALUE self)
{
    return get_vector(self)->compare_by_identity ? Qtrue : Qfalse;
}

static VALUE
vector_get_fast(VALUE self, VALUE index_value)
{
    vector_t *vector = get_vector(self);
    long long raw = vector_convert_index(index_value);
    size_t index;
    VALUE result = Qnil;
    pthread_mutex_lock(&vector->lock);
    if (vector_lookup_index(vector, raw, &index)) result = vector->values[index];
    pthread_mutex_unlock(&vector->lock);
    return result;
}

static VALUE
vector_get(int argc, VALUE *argv, VALUE self)
{
    VALUE index_value;
    VALUE keywords = Qnil;
    rb_scan_args(argc, argv, "1:", &index_value, &keywords);
    long long raw = vector_convert_index(index_value);
    vector_timeout_t timeout = vector_parse_timeout(vector_timeout_keyword(keywords));
    vector_t *vector = get_vector(self);

    if (!vector_lock_for_update(vector, &timeout)) return Qnil;
    size_t index;
    VALUE result = vector_lookup_index(vector, raw, &index) ? vector->values[index] : Qnil;
    pthread_mutex_unlock(&vector->lock);
    return result;
}

static VALUE
vector_store_internal(vector_t *vector, long long raw, VALUE value, vector_timeout_t *timeout)
{
    if (!vector_lock_for_update(vector, timeout)) return Qfalse;
    size_t index = vector_assignment_index(vector, raw);
    if (!vector_ensure_capacity(vector, index + 1)) {
        pthread_mutex_unlock(&vector->lock);
        rb_memerror();
    }
    if (index >= vector->size) vector->size = index + 1;
    vector->values[index] = value;
    vector_notify_waiters_locked(vector);
    pthread_mutex_unlock(&vector->lock);
    return value;
}

static VALUE
vector_set_fast(VALUE self, VALUE index_value, VALUE value)
{
    vector_t *vector = get_vector(self);
    long long raw = vector_convert_index(index_value);
    vector_timeout_t timeout = {.finite = false, .deadline = 0};
    containers_check_shareable(value);
    return vector_store_internal(vector, raw, value, &timeout);
}

static VALUE
vector_store(int argc, VALUE *argv, VALUE self)
{
    VALUE index_value;
    VALUE value;
    VALUE keywords = Qnil;
    rb_scan_args(argc, argv, "2:", &index_value, &value, &keywords);
    long long raw = vector_convert_index(index_value);
    vector_timeout_t timeout = vector_parse_timeout(vector_timeout_keyword(keywords));
    vector_t *vector = get_vector(self);
    containers_check_shareable(value);
    return vector_store_internal(vector, raw, value, &timeout);
}

static VALUE
vector_clear(VALUE self)
{
    vector_t *vector = get_vector(self);
    vector_timeout_t timeout = {.finite = false, .deadline = 0};
    (void)vector_lock_for_update(vector, &timeout);
    for (size_t index = 0; index < vector->size; index++) vector->values[index] = Qnil;
    vector->size = 0;
    vector_notify_waiters_locked(vector);
    pthread_mutex_unlock(&vector->lock);
    return self;
}

static VALUE
vector_push(int argc, VALUE *argv, VALUE self)
{
    VALUE value;
    VALUE keywords = Qnil;
    rb_scan_args(argc, argv, "1:", &value, &keywords);
    vector_timeout_t timeout = vector_parse_timeout(vector_timeout_keyword(keywords));
    vector_t *vector = get_vector(self);
    containers_check_shareable(value);

    if (!vector_lock_for_update(vector, &timeout)) return Qfalse;
    if (vector->size == SIZE_MAX || !vector_ensure_capacity(vector, vector->size + 1)) {
        pthread_mutex_unlock(&vector->lock);
        rb_memerror();
    }
    vector->values[vector->size++] = value;
    vector_notify_waiters_locked(vector);
    pthread_mutex_unlock(&vector->lock);
    return self;
}

static VALUE
vector_pop(int argc, VALUE *argv, VALUE self)
{
    VALUE keywords = Qnil;
    rb_scan_args(argc, argv, "0:", &keywords);
    vector_timeout_t timeout = vector_parse_timeout(vector_timeout_keyword(keywords));
    vector_t *vector = get_vector(self);

    if (!vector_lock_for_update(vector, &timeout)) return Qnil;
    VALUE result = Qnil;
    if (vector->size > 0) {
        size_t index = --vector->size;
        result = vector->values[index];
        vector->values[index] = Qnil;
        vector_notify_waiters_locked(vector);
    }
    pthread_mutex_unlock(&vector->lock);
    return result;
}

static VALUE
vector_swap(int argc, VALUE *argv, VALUE self)
{
    VALUE index_value;
    VALUE replacement;
    VALUE keywords = Qnil;
    rb_scan_args(argc, argv, "2:", &index_value, &replacement, &keywords);
    long long raw = vector_convert_index(index_value);
    vector_timeout_t timeout = vector_parse_timeout(vector_timeout_keyword(keywords));
    vector_t *vector = get_vector(self);
    containers_check_shareable(replacement);

    if (!vector_lock_for_update(vector, &timeout)) return Qnil;
    size_t index = vector_assignment_index(vector, raw);
    if (!vector_ensure_capacity(vector, index + 1)) {
        pthread_mutex_unlock(&vector->lock);
        rb_memerror();
    }
    VALUE previous = index < vector->size ? vector->values[index] : Qnil;
    if (index >= vector->size) vector->size = index + 1;
    vector->values[index] = replacement;
    vector_notify_waiters_locked(vector);
    pthread_mutex_unlock(&vector->lock);
    return previous;
}

typedef struct {
    vector_t *vector;
    size_t index;
    VALUE current;
    VALUE argument;
    VALUE replacement;
    bool identity;
    bool complete;
} vector_operation_t;

static VALUE
vector_operation_cleanup(VALUE opaque)
{
    vector_operation_t *operation = (vector_operation_t *)opaque;
    if (!operation->complete) {
        pthread_mutex_lock(&operation->vector->lock);
        vector_finish_update_locked(operation->vector);
        pthread_mutex_unlock(&operation->vector->lock);
    }
    return Qnil;
}

static VALUE
vector_store_if_absent_body(VALUE opaque)
{
    vector_operation_t *operation = (vector_operation_t *)opaque;
    VALUE result = rb_yield_values(0);
    containers_check_shareable(result);
    pthread_mutex_lock(&operation->vector->lock);
    if (operation->index >= operation->vector->size) {
        operation->vector->size = operation->index + 1;
    }
    operation->vector->values[operation->index] = result;
    vector_finish_update_locked(operation->vector);
    pthread_mutex_unlock(&operation->vector->lock);
    operation->complete = true;
    return result;
}

static VALUE
vector_store_if_absent(int argc, VALUE *argv, VALUE self)
{
    VALUE index_value;
    VALUE keywords = Qnil;
    rb_scan_args(argc, argv, "1:", &index_value, &keywords);
    long long raw = vector_convert_index(index_value);
    vector_timeout_t timeout = vector_parse_timeout(vector_timeout_keyword(keywords));
    vector_t *vector = get_vector(self);
    rb_need_block();

    if (!vector_lock_for_update(vector, &timeout)) return Qnil;
    size_t index = vector_assignment_index(vector, raw);
    if (!vector_ensure_capacity(vector, index + 1)) {
        pthread_mutex_unlock(&vector->lock);
        rb_memerror();
    }
    if (index < vector->size && !NIL_P(vector->values[index])) {
        VALUE value = vector->values[index];
        pthread_mutex_unlock(&vector->lock);
        return value;
    }

    vector_operation_t operation = {
        .vector = vector,
        .index = index,
        .complete = false,
    };
    vector->updating = true;
    pthread_mutex_unlock(&vector->lock);
    return rb_ensure(
        vector_store_if_absent_body,
        (VALUE)&operation,
        vector_operation_cleanup,
        (VALUE)&operation
    );
}

static VALUE
vector_cas_body(VALUE opaque)
{
    vector_operation_t *operation = (vector_operation_t *)opaque;
    bool matches = operation->identity
        ? operation->current == operation->argument
        : RTEST(rb_equal(operation->current, operation->argument));

    pthread_mutex_lock(&operation->vector->lock);
    if (matches) operation->vector->values[operation->index] = operation->replacement;
    vector_finish_update_locked(operation->vector);
    pthread_mutex_unlock(&operation->vector->lock);
    operation->complete = true;
    return matches ? Qtrue : Qfalse;
}

static VALUE
vector_compare_and_set(int argc, VALUE *argv, VALUE self)
{
    VALUE index_value;
    VALUE expected;
    VALUE replacement;
    VALUE keywords = Qnil;
    rb_scan_args(argc, argv, "3:", &index_value, &expected, &replacement, &keywords);
    long long raw = vector_convert_index(index_value);
    vector_timeout_t timeout = vector_parse_timeout(vector_timeout_keyword(keywords));
    vector_t *vector = get_vector(self);
    containers_check_shareable(expected);
    containers_check_shareable(replacement);

    if (!vector_lock_for_update(vector, &timeout)) return Qfalse;
    size_t index;
    if (!vector_lookup_index(vector, raw, &index)) {
        pthread_mutex_unlock(&vector->lock);
        return Qfalse;
    }
    vector_operation_t operation = {
        .vector = vector,
        .index = index,
        .current = vector->values[index],
        .argument = expected,
        .replacement = replacement,
        .identity = vector->compare_by_identity,
        .complete = false,
    };
    vector->updating = true;
    pthread_mutex_unlock(&vector->lock);
    return rb_ensure(vector_cas_body, (VALUE)&operation, vector_operation_cleanup, (VALUE)&operation);
}

static VALUE
vector_upsert_body(VALUE opaque)
{
    vector_operation_t *operation = (vector_operation_t *)opaque;
    VALUE result = rb_yield(operation->current);
    containers_check_shareable(result);
    pthread_mutex_lock(&operation->vector->lock);
    operation->vector->values[operation->index] = result;
    vector_finish_update_locked(operation->vector);
    pthread_mutex_unlock(&operation->vector->lock);
    operation->complete = true;
    return result;
}

static VALUE
vector_upsert(int argc, VALUE *argv, VALUE self)
{
    VALUE index_value;
    VALUE initial;
    VALUE keywords = Qnil;
    rb_scan_args(argc, argv, "2:", &index_value, &initial, &keywords);
    long long raw = vector_convert_index(index_value);
    vector_timeout_t timeout = vector_parse_timeout(vector_timeout_keyword(keywords));
    vector_t *vector = get_vector(self);
    containers_check_shareable(initial);
    rb_need_block();

    if (!vector_lock_for_update(vector, &timeout)) return Qnil;
    size_t index = vector_assignment_index(vector, raw);
    if (!vector_ensure_capacity(vector, index + 1)) {
        pthread_mutex_unlock(&vector->lock);
        rb_memerror();
    }
    if (index >= vector->size) vector->size = index + 1;
    if (NIL_P(vector->values[index])) {
        vector->values[index] = initial;
        vector_notify_waiters_locked(vector);
        pthread_mutex_unlock(&vector->lock);
        return initial;
    }

    vector_operation_t operation = {
        .vector = vector,
        .index = index,
        .current = vector->values[index],
        .complete = false,
    };
    vector->updating = true;
    pthread_mutex_unlock(&vector->lock);
    return rb_ensure(vector_upsert_body, (VALUE)&operation, vector_operation_cleanup, (VALUE)&operation);
}

static VALUE
vector_update_body(VALUE opaque)
{
    vector_operation_t *operation = (vector_operation_t *)opaque;
    VALUE result = rb_yield(operation->current);
    containers_check_shareable(result);
    pthread_mutex_lock(&operation->vector->lock);
    if (operation->index >= operation->vector->size) {
        operation->vector->size = operation->index + 1;
    }
    operation->vector->values[operation->index] = result;
    vector_finish_update_locked(operation->vector);
    pthread_mutex_unlock(&operation->vector->lock);
    operation->complete = true;
    return result;
}

static VALUE
vector_update(int argc, VALUE *argv, VALUE self)
{
    VALUE index_value;
    VALUE keywords = Qnil;
    rb_scan_args(argc, argv, "1:", &index_value, &keywords);
    long long raw = vector_convert_index(index_value);
    vector_timeout_t timeout = vector_parse_timeout(vector_timeout_keyword(keywords));
    vector_t *vector = get_vector(self);
    rb_need_block();

    if (!vector_lock_for_update(vector, &timeout)) return Qnil;
    size_t index = vector_assignment_index(vector, raw);
    if (!vector_ensure_capacity(vector, index + 1)) {
        pthread_mutex_unlock(&vector->lock);
        rb_memerror();
    }

    vector_operation_t operation = {
        .vector = vector,
        .index = index,
        .current = index < vector->size ? vector->values[index] : Qnil,
        .complete = false,
    };
    vector->updating = true;
    pthread_mutex_unlock(&vector->lock);
    return rb_ensure(vector_update_body, (VALUE)&operation, vector_operation_cleanup, (VALUE)&operation);
}

static bool
vector_values_equal(vector_t *vector, VALUE left, VALUE right)
{
    return vector->compare_by_identity ? left == right : RTEST(rb_equal(left, right));
}

static VALUE
vector_wait_until_changed(int argc, VALUE *argv, VALUE self)
{
    VALUE index_value;
    VALUE expected;
    VALUE keywords = Qnil;
    rb_scan_args(argc, argv, "2:", &index_value, &expected, &keywords);
    long long raw = vector_convert_index(index_value);
    vector_timeout_t timeout = vector_parse_timeout(vector_timeout_keyword(keywords));
    vector_t *vector = get_vector(self);
    containers_check_shareable(expected);

    for (;;) {
        uint64_t generation;
        size_t index;
        pthread_mutex_lock(&vector->lock);
        VALUE current = vector_lookup_index(vector, raw, &index) ? vector->values[index] : Qnil;
        generation = vector->generation;
        pthread_mutex_unlock(&vector->lock);

        if (!vector_values_equal(vector, current, expected)) return current;

        pthread_mutex_lock(&vector->lock);
        if (vector->generation != generation) {
            pthread_mutex_unlock(&vector->lock);
            continue;
        }
        if (!vector_wait_once(vector, &timeout)) return Qnil;
    }
}

static VALUE
vector_wait_until_non_nil(int argc, VALUE *argv, VALUE self)
{
    VALUE index_value;
    VALUE keywords = Qnil;
    rb_scan_args(argc, argv, "1:", &index_value, &keywords);
    long long raw = vector_convert_index(index_value);
    vector_timeout_t timeout = vector_parse_timeout(vector_timeout_keyword(keywords));
    vector_t *vector = get_vector(self);

    for (;;) {
        pthread_mutex_lock(&vector->lock);
        size_t index;
        VALUE current = vector_lookup_index(vector, raw, &index) ? vector->values[index] : Qnil;
        if (!NIL_P(current)) {
            pthread_mutex_unlock(&vector->lock);
            return current;
        }
        if (!vector_wait_once(vector, &timeout)) return Qnil;
    }
}

void
containers_init_vector(VALUE namespace)
{
    cVector = rb_define_class_under(namespace, "Vector", rb_cObject);
    rb_define_alloc_func(cVector, vector_allocate);
    rb_define_method(cVector, "initialize", vector_initialize, -1);
    rb_define_method(cVector, "size", vector_size, 0);
    rb_define_method(cVector, "snapshot", vector_snapshot, 0);
    rb_define_method(cVector, "clear", vector_clear, 0);
    rb_define_method(cVector, "[]", vector_get_fast, 1);
    rb_define_method(cVector, "[]=", vector_set_fast, 2);
    rb_define_method(cVector, "get", vector_get, -1);
    rb_define_method(cVector, "store", vector_store, -1);
    rb_define_method(cVector, "push", vector_push, -1);
    rb_define_method(cVector, "pop", vector_pop, -1);
    rb_define_method(cVector, "swap", vector_swap, -1);
    rb_define_method(cVector, "store_if_absent", vector_store_if_absent, -1);
    rb_define_method(cVector, "compare_and_set", vector_compare_and_set, -1);
    rb_define_method(cVector, "upsert", vector_upsert, -1);
    rb_define_method(cVector, "update", vector_update, -1);
    rb_define_method(cVector, "wait_until_changed", vector_wait_until_changed, -1);
    rb_define_method(cVector, "wait_until_non_nil", vector_wait_until_non_nil, -1);
    rb_define_method(cVector, "compare_by_identity?", vector_compare_by_identity_p, 0);
}
