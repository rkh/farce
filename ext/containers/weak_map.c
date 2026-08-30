#include "containers.h"

#ifdef RC_HAVE_NATIVE_WEAK_MAPS

#include "ruby/io.h"

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#define WEAK_MAP_INITIAL_CAPACITY 16

/* These functions are exported by Rubies with the probed typed-data weak
 * reference callback, but their declarations intentionally remain internal. */
void rb_gc_declare_weak_references(VALUE object);
bool rb_gc_handle_weak_references_alive_p(VALUE object);

static VALUE cWeakKeyMap;
static VALUE cWeakValueMap;
static VALUE cWeakMap;

typedef enum {
    WEAK_MAP_EMPTY = 0,
    WEAK_MAP_OCCUPIED = 1,
    WEAK_MAP_TOMBSTONE = 2
} weak_map_slot_state_t;

typedef struct {
    VALUE key;
    VALUE value;
    st_index_t hash;
    weak_map_slot_state_t state;
} weak_map_slot_t;

typedef struct weak_map_waiter {
    int read_fd;
    int write_fd;
    bool notified;
    struct weak_map_waiter *next;
} weak_map_waiter_t;

typedef struct {
    pthread_mutex_t lock;
    weak_map_slot_t *slots;
    size_t capacity;
    size_t size;
    size_t tombstones;
    uint64_t generation;
    weak_map_waiter_t *waiters;
    bool compare_keys_by_identity;
    bool compare_values_by_identity;
    bool weak_keys;
    bool weak_values;
    bool updating;
    bool initialized;
} weak_map_t;

typedef struct {
    bool finite;
    double deadline;
} weak_map_timeout_t;

static double
weak_map_monotonic_now(void)
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

static weak_map_timeout_t
weak_map_parse_timeout(VALUE timeout)
{
    weak_map_timeout_t parsed = {.finite = false, .deadline = 0};
    if (NIL_P(timeout)) return parsed;
    double seconds = NUM2DBL(timeout);
    if (!isfinite(seconds) || seconds < 0) {
        rb_raise(rb_eArgError, "timeout must be a finite, non-negative number or nil");
    }
    parsed.finite = true;
    parsed.deadline = weak_map_monotonic_now() + seconds;
    return parsed;
}

static void
weak_map_set_fd_flags(int fd)
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

static void
weak_map_waiter_initialize(weak_map_waiter_t *waiter)
{
    int descriptors[2];
    if (pipe(descriptors) != 0) rb_sys_fail("pipe");
    waiter->read_fd = descriptors[0];
    waiter->write_fd = descriptors[1];
    waiter->notified = false;
    waiter->next = NULL;
    weak_map_set_fd_flags(waiter->read_fd);
    weak_map_set_fd_flags(waiter->write_fd);
}

static void
weak_map_notify_waiters_locked(weak_map_t *map)
{
    unsigned char byte = 1;
    map->generation++;
    for (weak_map_waiter_t *waiter = map->waiters; waiter; waiter = waiter->next) {
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
weak_map_mark(void *pointer)
{
    weak_map_t *map = pointer;
    if (!map->slots) return;

    for (size_t index = 0; index < map->capacity; index++) {
        weak_map_slot_t *slot = &map->slots[index];
        if (slot->state != WEAK_MAP_OCCUPIED) continue;
        if (!map->weak_keys) rb_gc_mark_movable(slot->key);
        if (!map->weak_values) rb_gc_mark_movable(slot->value);
    }
}

static void
weak_map_compact(void *pointer)
{
    weak_map_t *map = pointer;
    if (!map->slots) return;

    for (size_t index = 0; index < map->capacity; index++) {
        weak_map_slot_t *slot = &map->slots[index];
        if (slot->state != WEAK_MAP_OCCUPIED) continue;
        slot->key = rb_gc_location(slot->key);
        slot->value = rb_gc_location(slot->value);
    }
}

/* The VM invokes this after marking while mutators are stopped. Taking the map
 * mutex here could deadlock if GC stopped a mutator at a safepoint while it
 * owned the mutex, so cleanup deliberately runs lock-free. */
static void
weak_map_handle_weak_references(void *pointer)
{
    weak_map_t *map = pointer;
    if (!map->slots) return;
    bool changed = false;

    for (size_t index = 0; index < map->capacity; index++) {
        weak_map_slot_t *slot = &map->slots[index];
        if (slot->state != WEAK_MAP_OCCUPIED) continue;

        bool key_alive = !map->weak_keys || rb_gc_handle_weak_references_alive_p(slot->key);
        bool value_alive = !map->weak_values || rb_gc_handle_weak_references_alive_p(slot->value);
        if (key_alive && value_alive) continue;

        slot->key = Qnil;
        slot->value = Qnil;
        slot->state = WEAK_MAP_TOMBSTONE;
        map->size--;
        map->tombstones++;
        changed = true;
    }
    if (changed) weak_map_notify_waiters_locked(map);
}

static void
weak_map_free(void *pointer)
{
    weak_map_t *map = pointer;
    pthread_mutex_destroy(&map->lock);
    free(map->slots);
    ruby_xfree(map);
}

static size_t
weak_map_memsize(const void *pointer)
{
    const weak_map_t *map = pointer;
    return map ? sizeof(weak_map_t) + map->capacity * sizeof(weak_map_slot_t) : 0;
}

static const rb_data_type_t weak_map_type = {
    .wrap_struct_name = "Ractor::Containers::WeakMap",
    .function = {
        .dmark = weak_map_mark,
        .dfree = weak_map_free,
        .dsize = weak_map_memsize,
        .dcompact = weak_map_compact,
        .handle_weak_references = weak_map_handle_weak_references,
    },
    .flags = RUBY_TYPED_FROZEN_SHAREABLE,
};

static weak_map_slot_t *
weak_map_allocate_slots(size_t capacity)
{
    weak_map_slot_t *slots = calloc(capacity, sizeof(weak_map_slot_t));
    if (!slots) rb_memerror();
    return slots;
}

static VALUE
weak_map_allocate(VALUE klass)
{
    weak_map_t *map;
    VALUE object = TypedData_Make_Struct(klass, weak_map_t, &weak_map_type, map);
    pthread_mutex_init(&map->lock, NULL);
    map->slots = NULL;
    map->capacity = 0;
    map->size = 0;
    map->tombstones = 0;
    map->generation = 0;
    map->waiters = NULL;
    map->compare_keys_by_identity = false;
    map->compare_values_by_identity = false;
    map->weak_keys = klass == cWeakKeyMap || klass == cWeakMap;
    map->weak_values = klass == cWeakValueMap || klass == cWeakMap;
    map->updating = false;
    map->initialized = false;
    return object;
}

static weak_map_t *
get_weak_map(VALUE self)
{
    weak_map_t *map;
    TypedData_Get_Struct(self, weak_map_t, &weak_map_type, map);
    if (!map->initialized) rb_raise(rb_eRuntimeError, "uninitialized weak map");
    return map;
}

typedef struct {
    weak_map_t *map;
    weak_map_waiter_t *waiter;
    weak_map_timeout_t *timeout;
    bool registered;
} weak_map_wait_context_t;

static VALUE
weak_map_wait_body(VALUE opaque)
{
    weak_map_wait_context_t *context = (weak_map_wait_context_t *)opaque;
    VALUE wait_timeout = Qnil;
    if (context->timeout->finite) {
        double remaining = context->timeout->deadline - weak_map_monotonic_now();
        if (remaining <= 0) return Qfalse;
        wait_timeout = DBL2NUM(remaining);
    }
    VALUE io = rb_io_open_descriptor(
        rb_cIO,
        context->waiter->read_fd,
        FMODE_READABLE | FMODE_EXTERNAL,
        Qnil,
        Qnil,
        NULL
    );
    VALUE result = rb_io_wait(io, INT2NUM(RUBY_IO_READABLE), wait_timeout);
    RB_GC_GUARD(io);
    return RTEST(result) ? Qtrue : Qfalse;
}

static VALUE
weak_map_wait_cleanup(VALUE opaque)
{
    weak_map_wait_context_t *context = (weak_map_wait_context_t *)opaque;
    if (context->registered) {
        pthread_mutex_lock(&context->map->lock);
        weak_map_waiter_t **cursor = &context->map->waiters;
        while (*cursor && *cursor != context->waiter) cursor = &(*cursor)->next;
        if (*cursor) *cursor = context->waiter->next;
        pthread_mutex_unlock(&context->map->lock);
        context->registered = false;
    }
    close(context->waiter->read_fd);
    close(context->waiter->write_fd);
    return Qnil;
}

static bool
weak_map_wait_once(weak_map_t *map, uint64_t generation, weak_map_timeout_t *timeout)
{
    weak_map_waiter_t waiter;
    weak_map_waiter_initialize(&waiter);

    pthread_mutex_lock(&map->lock);
    if (map->generation != generation) {
        pthread_mutex_unlock(&map->lock);
        close(waiter.read_fd);
        close(waiter.write_fd);
        return true;
    }
    waiter.next = map->waiters;
    map->waiters = &waiter;
    pthread_mutex_unlock(&map->lock);

    weak_map_wait_context_t context = {
        .map = map,
        .waiter = &waiter,
        .timeout = timeout,
        .registered = true,
    };
    return RTEST(rb_ensure(
        weak_map_wait_body,
        (VALUE)&context,
        weak_map_wait_cleanup,
        (VALUE)&context
    ));
}

static bool
weak_map_lock_for_update_with_timeout(weak_map_t *map, weak_map_timeout_t *timeout)
{
    for (;;) {
        pthread_mutex_lock(&map->lock);
        if (!map->updating) return true;
        uint64_t generation = map->generation;
        pthread_mutex_unlock(&map->lock);
        if (!weak_map_wait_once(map, generation, timeout)) return false;
    }
}

static VALUE
weak_map_timeout_result(void)
{
    return rb_block_given_p() ? rb_yield_values(0) : Qnil;
}

static void
weak_map_lock_for_update(weak_map_t *map)
{
    for (;;) {
        pthread_mutex_lock(&map->lock);
        if (!map->updating) return;
        pthread_mutex_unlock(&map->lock);
        containers_brief_wait();
    }
}

static st_index_t
weak_map_key_hash(weak_map_t *map, VALUE key)
{
    if (map->compare_keys_by_identity) {
        return (st_index_t)NUM2ULL(rb_obj_id(key));
    }
    return (st_index_t)NUM2LONG(rb_hash(key));
}

typedef struct {
    VALUE left;
    VALUE right;
} weak_map_eql_arguments_t;

static VALUE
weak_map_eql_protected(VALUE opaque)
{
    weak_map_eql_arguments_t *arguments = (weak_map_eql_arguments_t *)opaque;
    return rb_eql(arguments->left, arguments->right) ? Qtrue : Qfalse;
}

static bool
weak_map_keys_equal(weak_map_t *map, VALUE left, VALUE right)
{
    if (map->compare_keys_by_identity) return left == right;

    weak_map_eql_arguments_t arguments = {.left = left, .right = right};
    int state = 0;
    VALUE result = rb_protect(weak_map_eql_protected, (VALUE)&arguments, &state);
    if (state) {
        pthread_mutex_unlock(&map->lock);
        rb_jump_tag(state);
    }
    return RTEST(result);
}

static size_t
weak_map_find_slot(weak_map_t *map, VALUE key, st_index_t hash, bool *found)
{
    size_t mask = map->capacity - 1;
    size_t first_tombstone = SIZE_MAX;
    for (size_t offset = 0; offset < map->capacity; offset++) {
        size_t index = ((size_t)hash + offset) & mask;
        weak_map_slot_t *slot = &map->slots[index];
        if (slot->state == WEAK_MAP_EMPTY) {
            *found = false;
            return first_tombstone == SIZE_MAX ? index : first_tombstone;
        }
        if (slot->state == WEAK_MAP_TOMBSTONE) {
            if (first_tombstone == SIZE_MAX) first_tombstone = index;
            continue;
        }
        if (slot->hash == hash && weak_map_keys_equal(map, slot->key, key)) {
            *found = true;
            return index;
        }
    }
    *found = false;
    return first_tombstone;
}

static void
weak_map_resize(weak_map_t *map, size_t new_capacity)
{
    weak_map_slot_t *old_slots = map->slots;
    size_t old_capacity = map->capacity;
    map->slots = weak_map_allocate_slots(new_capacity);
    map->capacity = new_capacity;
    map->size = 0;
    map->tombstones = 0;

    for (size_t index = 0; index < old_capacity; index++) {
        weak_map_slot_t *old = &old_slots[index];
        if (old->state != WEAK_MAP_OCCUPIED) continue;

        size_t mask = map->capacity - 1;
        size_t target = (size_t)old->hash & mask;
        while (map->slots[target].state == WEAK_MAP_OCCUPIED) {
            target = (target + 1) & mask;
        }
        map->slots[target] = *old;
        map->size++;
    }
    free(old_slots);
}

static void
weak_map_prepare_insert(weak_map_t *map)
{
    if ((map->size + map->tombstones + 1) * 10 >= map->capacity * 7) {
        weak_map_resize(map, map->capacity * 2);
    }
}

static VALUE
weak_map_store_locked(VALUE self, weak_map_t *map, VALUE key, VALUE value, st_index_t hash)
{
    bool found;
    weak_map_prepare_insert(map);
    size_t index = weak_map_find_slot(map, key, hash, &found);
    weak_map_slot_t *slot = &map->slots[index];
    if (!found) {
        if (slot->state == WEAK_MAP_TOMBSTONE) map->tombstones--;
        slot->key = key;
        slot->hash = hash;
        slot->state = WEAK_MAP_OCCUPIED;
        map->size++;
    }
    slot->value = value;
    RB_OBJ_WRITTEN(self, Qundef, key);
    RB_OBJ_WRITTEN(self, Qundef, value);
    weak_map_notify_waiters_locked(map);
    return value;
}

typedef struct {
    VALUE self;
    weak_map_t *map;
} weak_map_init_context_t;

static int
weak_map_initialize_entry(VALUE key, VALUE value, VALUE opaque)
{
    weak_map_init_context_t *context = (weak_map_init_context_t *)opaque;
    containers_check_shareable(key);
    containers_check_shareable(value);
    st_index_t hash = weak_map_key_hash(context->map, key);
    pthread_mutex_lock(&context->map->lock);
    weak_map_store_locked(context->self, context->map, key, value, hash);
    pthread_mutex_unlock(&context->map->lock);
    return ST_CONTINUE;
}

static VALUE
weak_map_initialize(int argc, VALUE *argv, VALUE self)
{
    VALUE mapping = Qnil;
    VALUE keywords = Qnil;
    ID keyword_ids[] = {
        rb_intern("compare_by_identity"),
        rb_intern("compare_keys_by_identity"),
        rb_intern("compare_values_by_identity")
    };
    VALUE keyword_values[3] = {Qundef, Qundef, Qundef};
    weak_map_t *map;

    rb_scan_args(argc, argv, "01:", &mapping, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 3, keyword_values);
    TypedData_Get_Struct(self, weak_map_t, &weak_map_type, map);
    if (map->initialized) rb_raise(rb_eRuntimeError, "weak map is already initialized");

    bool common = keyword_values[0] == Qundef
        ? false
        : containers_strict_bool(keyword_values[0], "compare_by_identity");
    map->compare_keys_by_identity = keyword_values[1] == Qundef
        ? common
        : containers_strict_bool(keyword_values[1], "compare_keys_by_identity");
    map->compare_values_by_identity = keyword_values[2] == Qundef
        ? common
        : containers_strict_bool(keyword_values[2], "compare_values_by_identity");
    map->capacity = WEAK_MAP_INITIAL_CAPACITY;
    map->slots = weak_map_allocate_slots(map->capacity);

    rb_gc_declare_weak_references(self);
    if (!NIL_P(mapping)) {
        Check_Type(mapping, T_HASH);
        weak_map_init_context_t context = {.self = self, .map = map};
        rb_hash_foreach(mapping, weak_map_initialize_entry, (VALUE)&context);
    }
    map->initialized = true;
    containers_finish_initialization(self);
    return self;
}

static VALUE
weak_map_get(VALUE self, VALUE key)
{
    weak_map_t *map = get_weak_map(self);
    containers_check_shareable(key);
    st_index_t hash = weak_map_key_hash(map, key);
    bool found;
    VALUE result = Qnil;
    pthread_mutex_lock(&map->lock);
    size_t index = weak_map_find_slot(map, key, hash, &found);
    if (found) result = map->slots[index].value;
    pthread_mutex_unlock(&map->lock);
    return result;
}

static VALUE
weak_map_set(VALUE self, VALUE key, VALUE value)
{
    weak_map_t *map = get_weak_map(self);
    containers_check_shareable(key);
    containers_check_shareable(value);
    st_index_t hash = weak_map_key_hash(map, key);
    weak_map_lock_for_update(map);
    weak_map_store_locked(self, map, key, value, hash);
    pthread_mutex_unlock(&map->lock);
    return value;
}

static VALUE
weak_map_key_p(VALUE self, VALUE key)
{
    weak_map_t *map = get_weak_map(self);
    containers_check_shareable(key);
    st_index_t hash = weak_map_key_hash(map, key);
    bool found;
    pthread_mutex_lock(&map->lock);
    (void)weak_map_find_slot(map, key, hash, &found);
    pthread_mutex_unlock(&map->lock);
    return found ? Qtrue : Qfalse;
}

static VALUE
weak_map_getkey(VALUE self, VALUE key)
{
    weak_map_t *map = get_weak_map(self);
    containers_check_shareable(key);
    st_index_t hash = weak_map_key_hash(map, key);
    bool found;
    VALUE result = Qnil;
    pthread_mutex_lock(&map->lock);
    size_t index = weak_map_find_slot(map, key, hash, &found);
    if (found) result = map->compare_keys_by_identity ? key : map->slots[index].key;
    pthread_mutex_unlock(&map->lock);
    return result;
}

static VALUE
weak_map_delete(VALUE self, VALUE key)
{
    weak_map_t *map = get_weak_map(self);
    containers_check_shareable(key);
    st_index_t hash = weak_map_key_hash(map, key);
    bool found;
    VALUE result = Qnil;
    weak_map_lock_for_update(map);
    size_t index = weak_map_find_slot(map, key, hash, &found);
    if (found) {
        weak_map_slot_t *slot = &map->slots[index];
        result = slot->value;
        slot->key = Qnil;
        slot->value = Qnil;
        slot->state = WEAK_MAP_TOMBSTONE;
        map->size--;
        map->tombstones++;
        weak_map_notify_waiters_locked(map);
    }
    pthread_mutex_unlock(&map->lock);
    return result;
}

typedef struct {
    VALUE self;
    weak_map_t *map;
    VALUE key;
    VALUE current;
    VALUE argument;
    VALUE replacement;
    st_index_t hash;
    bool identity;
    bool complete;
} weak_map_operation_t;

static VALUE
weak_map_operation_cleanup(VALUE opaque)
{
    weak_map_operation_t *operation = (weak_map_operation_t *)opaque;
    if (!operation->complete) {
        pthread_mutex_lock(&operation->map->lock);
        operation->map->updating = false;
        weak_map_notify_waiters_locked(operation->map);
        pthread_mutex_unlock(&operation->map->lock);
    }
    return Qnil;
}

static VALUE
weak_map_store_body(VALUE opaque)
{
    weak_map_operation_t *operation = (weak_map_operation_t *)opaque;
    VALUE result = rb_yield_values(0);
    containers_check_shareable(result);
    pthread_mutex_lock(&operation->map->lock);
    weak_map_store_locked(operation->self, operation->map, operation->key, result, operation->hash);
    operation->map->updating = false;
    pthread_mutex_unlock(&operation->map->lock);
    operation->complete = true;
    return result;
}

static VALUE
weak_map_store_if_absent(int argc, VALUE *argv, VALUE self)
{
    VALUE key;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    rb_scan_args(argc, argv, "1:", &key, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    weak_map_t *map = get_weak_map(self);
    weak_map_operation_t operation = {
        .self = self,
        .map = map,
        .key = key,
        .complete = false,
    };
    containers_check_shareable(key);
    rb_need_block();
    operation.hash = weak_map_key_hash(map, key);
    weak_map_timeout_t timeout = weak_map_parse_timeout(
        keyword_values[0] == Qundef ? Qnil : keyword_values[0]
    );

    if (!weak_map_lock_for_update_with_timeout(map, &timeout)) return Qnil;
    bool found;
    size_t index = weak_map_find_slot(map, key, operation.hash, &found);
    if (found) {
        VALUE value = map->slots[index].value;
        pthread_mutex_unlock(&map->lock);
        return value;
    }
    map->updating = true;
    pthread_mutex_unlock(&map->lock);
    return rb_ensure(weak_map_store_body, (VALUE)&operation, weak_map_operation_cleanup, (VALUE)&operation);
}

static VALUE
weak_map_cas_body(VALUE opaque)
{
    weak_map_operation_t *operation = (weak_map_operation_t *)opaque;
    bool matches = operation->identity
        ? operation->current == operation->argument
        : RTEST(rb_equal(operation->current, operation->argument));

    pthread_mutex_lock(&operation->map->lock);
    if (matches) {
        weak_map_store_locked(
            operation->self,
            operation->map,
            operation->key,
            operation->replacement,
            operation->hash
        );
    }
    operation->map->updating = false;
    if (!matches) weak_map_notify_waiters_locked(operation->map);
    pthread_mutex_unlock(&operation->map->lock);
    operation->complete = true;
    return matches ? Qtrue : Qfalse;
}

static VALUE
weak_map_compare_and_set(int argc, VALUE *argv, VALUE self)
{
    VALUE key;
    VALUE expected;
    VALUE replacement;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    rb_scan_args(argc, argv, "3:", &key, &expected, &replacement, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    weak_map_t *map = get_weak_map(self);
    weak_map_operation_t operation = {
        .self = self,
        .map = map,
        .key = key,
        .argument = expected,
        .replacement = replacement,
        .identity = map->compare_values_by_identity,
        .complete = false,
    };
    containers_check_shareable(key);
    containers_check_shareable(expected);
    containers_check_shareable(replacement);
    operation.hash = weak_map_key_hash(map, key);
    weak_map_timeout_t timeout = weak_map_parse_timeout(
        keyword_values[0] == Qundef ? Qnil : keyword_values[0]
    );

    if (!weak_map_lock_for_update_with_timeout(map, &timeout)) return Qfalse;
    bool found;
    size_t index = weak_map_find_slot(map, key, operation.hash, &found);
    if (!found) {
        pthread_mutex_unlock(&map->lock);
        return Qfalse;
    }
    operation.current = map->slots[index].value;
    map->updating = true;
    pthread_mutex_unlock(&map->lock);
    return rb_ensure(weak_map_cas_body, (VALUE)&operation, weak_map_operation_cleanup, (VALUE)&operation);
}

static VALUE
weak_map_upsert_body(VALUE opaque)
{
    weak_map_operation_t *operation = (weak_map_operation_t *)opaque;
    VALUE result = rb_yield(operation->current);
    containers_check_shareable(result);
    pthread_mutex_lock(&operation->map->lock);
    weak_map_store_locked(operation->self, operation->map, operation->key, result, operation->hash);
    operation->map->updating = false;
    pthread_mutex_unlock(&operation->map->lock);
    operation->complete = true;
    return result;
}

static VALUE
weak_map_upsert(int argc, VALUE *argv, VALUE self)
{
    VALUE key;
    VALUE initial;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    rb_scan_args(argc, argv, "2:", &key, &initial, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    weak_map_t *map = get_weak_map(self);
    weak_map_operation_t operation = {
        .self = self,
        .map = map,
        .key = key,
        .complete = false,
    };
    containers_check_shareable(key);
    containers_check_shareable(initial);
    rb_need_block();
    operation.hash = weak_map_key_hash(map, key);
    weak_map_timeout_t timeout = weak_map_parse_timeout(
        keyword_values[0] == Qundef ? Qnil : keyword_values[0]
    );

    if (!weak_map_lock_for_update_with_timeout(map, &timeout)) return Qnil;
    bool found;
    size_t index = weak_map_find_slot(map, key, operation.hash, &found);
    if (!found) {
        weak_map_store_locked(self, map, key, initial, operation.hash);
        pthread_mutex_unlock(&map->lock);
        return initial;
    }
    operation.current = map->slots[index].value;
    map->updating = true;
    pthread_mutex_unlock(&map->lock);
    return rb_ensure(weak_map_upsert_body, (VALUE)&operation, weak_map_operation_cleanup, (VALUE)&operation);
}

static VALUE
weak_map_compare_keys_by_identity_p(VALUE self)
{
    return get_weak_map(self)->compare_keys_by_identity ? Qtrue : Qfalse;
}

static VALUE
weak_map_compare_values_by_identity_p(VALUE self)
{
    return get_weak_map(self)->compare_values_by_identity ? Qtrue : Qfalse;
}

static VALUE
weak_map_weak_keys_p(VALUE self)
{
    return get_weak_map(self)->weak_keys ? Qtrue : Qfalse;
}

static VALUE
weak_map_weak_values_p(VALUE self)
{
    return get_weak_map(self)->weak_values ? Qtrue : Qfalse;
}

static VALUE
weak_map_size(VALUE self)
{
    weak_map_t *map = get_weak_map(self);
    size_t size;
    pthread_mutex_lock(&map->lock);
    size = map->size;
    pthread_mutex_unlock(&map->lock);
    return SIZET2NUM(size);
}

static VALUE
weak_map_get_with_timeout(int argc, VALUE *argv, VALUE self)
{
    VALUE key;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    rb_scan_args(argc, argv, "1:", &key, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    weak_map_t *map = get_weak_map(self);
    containers_check_shareable(key);
    st_index_t hash = weak_map_key_hash(map, key);
    weak_map_timeout_t timeout = weak_map_parse_timeout(
        keyword_values[0] == Qundef ? Qnil : keyword_values[0]
    );
    if (!weak_map_lock_for_update_with_timeout(map, &timeout)) return weak_map_timeout_result();

    bool found;
    size_t index = weak_map_find_slot(map, key, hash, &found);
    VALUE result = found ? map->slots[index].value : Qnil;
    pthread_mutex_unlock(&map->lock);
    return result;
}

static VALUE
weak_map_store_with_timeout(int argc, VALUE *argv, VALUE self)
{
    VALUE key;
    VALUE value;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    rb_scan_args(argc, argv, "2:", &key, &value, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    weak_map_t *map = get_weak_map(self);
    containers_check_shareable(key);
    containers_check_shareable(value);
    st_index_t hash = weak_map_key_hash(map, key);
    weak_map_timeout_t timeout = weak_map_parse_timeout(
        keyword_values[0] == Qundef ? Qnil : keyword_values[0]
    );
    if (!weak_map_lock_for_update_with_timeout(map, &timeout)) return weak_map_timeout_result();
    weak_map_store_locked(self, map, key, value, hash);
    pthread_mutex_unlock(&map->lock);
    return value;
}

static VALUE
weak_map_swap(int argc, VALUE *argv, VALUE self)
{
    VALUE key;
    VALUE replacement;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    rb_scan_args(argc, argv, "2:", &key, &replacement, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    weak_map_t *map = get_weak_map(self);
    containers_check_shareable(key);
    containers_check_shareable(replacement);
    st_index_t hash = weak_map_key_hash(map, key);
    weak_map_timeout_t timeout = weak_map_parse_timeout(
        keyword_values[0] == Qundef ? Qnil : keyword_values[0]
    );
    if (!weak_map_lock_for_update_with_timeout(map, &timeout)) return weak_map_timeout_result();

    bool found;
    size_t index = weak_map_find_slot(map, key, hash, &found);
    VALUE previous = found ? map->slots[index].value : Qnil;
    weak_map_store_locked(self, map, key, replacement, hash);
    pthread_mutex_unlock(&map->lock);
    return previous;
}

static bool
weak_map_values_equal(weak_map_t *map, VALUE left, VALUE right)
{
    return map->compare_values_by_identity ? left == right : RTEST(rb_equal(left, right));
}

static VALUE
weak_map_wait_for_value(int argc, VALUE *argv, VALUE self, bool non_nil)
{
    VALUE key;
    VALUE expected = Qnil;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    if (non_nil) rb_scan_args(argc, argv, "1:", &key, &keywords);
    else rb_scan_args(argc, argv, "2:", &key, &expected, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    weak_map_t *map = get_weak_map(self);
    containers_check_shareable(key);
    if (!non_nil) containers_check_shareable(expected);
    st_index_t hash = weak_map_key_hash(map, key);
    weak_map_timeout_t timeout = weak_map_parse_timeout(
        keyword_values[0] == Qundef ? Qnil : keyword_values[0]
    );

    for (;;) {
        bool found;
        VALUE current = Qnil;
        uint64_t generation;
        pthread_mutex_lock(&map->lock);
        size_t index = weak_map_find_slot(map, key, hash, &found);
        if (found) current = map->slots[index].value;
        generation = map->generation;
        pthread_mutex_unlock(&map->lock);

        bool ready = non_nil ? !NIL_P(current) : !weak_map_values_equal(map, current, expected);
        if (ready) return current;
        if (!weak_map_wait_once(map, generation, &timeout)) return weak_map_timeout_result();
    }
}

static VALUE
weak_map_wait_until_changed(int argc, VALUE *argv, VALUE self)
{
    return weak_map_wait_for_value(argc, argv, self, false);
}

static VALUE
weak_map_wait_until_non_nil(int argc, VALUE *argv, VALUE self)
{
    return weak_map_wait_for_value(argc, argv, self, true);
}

static VALUE
weak_map_update(int argc, VALUE *argv, VALUE self)
{
    VALUE key;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    rb_scan_args(argc, argv, "1:", &key, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    weak_map_t *map = get_weak_map(self);
    weak_map_operation_t operation = {
        .self = self,
        .map = map,
        .key = key,
        .complete = false,
    };
    containers_check_shareable(key);
    rb_need_block();
    operation.hash = weak_map_key_hash(map, key);
    weak_map_timeout_t timeout = weak_map_parse_timeout(
        keyword_values[0] == Qundef ? Qnil : keyword_values[0]
    );

    if (!weak_map_lock_for_update_with_timeout(map, &timeout)) return Qnil;
    bool found;
    size_t index = weak_map_find_slot(map, key, operation.hash, &found);
    operation.current = found ? map->slots[index].value : Qnil;
    map->updating = true;
    pthread_mutex_unlock(&map->lock);
    return rb_ensure(
        weak_map_upsert_body,
        (VALUE)&operation,
        weak_map_operation_cleanup,
        (VALUE)&operation
    );
}

static void
define_weak_map_methods(VALUE klass)
{
    rb_define_alloc_func(klass, weak_map_allocate);
    rb_define_method(klass, "initialize", weak_map_initialize, -1);
    rb_define_method(klass, "[]", weak_map_get, 1);
    rb_define_method(klass, "[]=", weak_map_set, 2);
    rb_define_method(klass, "get", weak_map_get_with_timeout, -1);
    rb_define_method(klass, "store", weak_map_store_with_timeout, -1);
    rb_define_method(klass, "swap", weak_map_swap, -1);
    rb_define_method(klass, "update", weak_map_update, -1);
    rb_define_method(klass, "wait_until_changed", weak_map_wait_until_changed, -1);
    rb_define_method(klass, "wait_until_non_nil", weak_map_wait_until_non_nil, -1);
    rb_define_method(klass, "store_if_absent", weak_map_store_if_absent, -1);
    rb_define_method(klass, "key?", weak_map_key_p, 1);
    rb_define_method(klass, "delete", weak_map_delete, 1);
    rb_define_method(klass, "compare_and_set", weak_map_compare_and_set, -1);
    rb_define_method(klass, "upsert", weak_map_upsert, -1);
    rb_define_method(klass, "compare_keys_by_identity?", weak_map_compare_keys_by_identity_p, 0);
    rb_define_method(klass, "compare_values_by_identity?", weak_map_compare_values_by_identity_p, 0);
    rb_define_method(klass, "weak_keys?", weak_map_weak_keys_p, 0);
    rb_define_method(klass, "weak_values?", weak_map_weak_values_p, 0);
    rb_define_method(klass, "getkey", weak_map_getkey, 1);
    rb_define_method(klass, "size", weak_map_size, 0);
}

void
containers_init_weak_maps(VALUE namespace)
{
    cWeakKeyMap = rb_define_class_under(namespace, "WeakKeyMap", rb_cObject);
    cWeakValueMap = rb_define_class_under(namespace, "WeakValueMap", rb_cObject);
    cWeakMap = rb_define_class_under(namespace, "WeakMap", rb_cObject);
    define_weak_map_methods(cWeakKeyMap);
    define_weak_map_methods(cWeakValueMap);
    define_weak_map_methods(cWeakMap);
    rb_define_const(namespace, "NATIVE_WEAK_MAPS", Qtrue);
}

#else

void
containers_init_weak_maps(VALUE namespace)
{
    (void)namespace;
}

#endif
