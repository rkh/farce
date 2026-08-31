#include "containers.h"
#include "ruby/fiber/scheduler.h"
#include "ruby/io.h"

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>

static VALUE cAtom;

typedef struct atom_waiter atom_waiter_t;

struct atom_waiter {
    int read_fd;
    int write_fd;
    bool notified;
    atom_waiter_t *next;
};

typedef struct {
    pthread_mutex_t lock;
    VALUE value;
    atom_waiter_t *waiters;
    uint64_t version;
    bool compare_by_identity;
    bool updating;
    VALUE updating_fiber;
    VALUE updating_thread;
    bool initialized;
} atom_t;

typedef struct {
    bool finite;
    double deadline;
} atom_timeout_t;

static bool atom_wait_once(atom_t *atom, atom_timeout_t *timeout);

static double
atom_monotonic_now(void)
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

static atom_timeout_t
atom_parse_timeout(VALUE timeout)
{
    atom_timeout_t parsed = {.finite = false, .deadline = 0};
    if (NIL_P(timeout)) return parsed;
    double seconds = NUM2DBL(timeout);
    if (!isfinite(seconds) || seconds < 0) {
        rb_raise(rb_eArgError, "timeout must be a finite, non-negative number or nil");
    }
    parsed.finite = true;
    parsed.deadline = atom_monotonic_now() + seconds;
    return parsed;
}

static void
atom_set_fd_flags(int fd)
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

/* Called with atom->lock held. Every waiter owns a separate descriptor, so a
 * single state transition can wake all waiters without consuming a shared
 * notification. */
static void
atom_notify_waiters(atom_t *atom)
{
    unsigned char byte = 1;
    for (atom_waiter_t *waiter = atom->waiters; waiter; waiter = waiter->next) {
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
atom_changed(atom_t *atom)
{
    atom->version++;
    atom_notify_waiters(atom);
}

static void
atom_finished_update(atom_t *atom, bool changed)
{
    if (changed) atom->version++;
    atom->updating = false;
    atom->updating_fiber = Qnil;
    atom->updating_thread = Qnil;
    atom_notify_waiters(atom);
}

static void
atom_mark(void *pointer)
{
    atom_t *atom = pointer;
    rb_gc_mark_movable(atom->value);
    rb_gc_mark_movable(atom->updating_fiber);
    rb_gc_mark_movable(atom->updating_thread);
}
static void
atom_compact(void *pointer)
{
    atom_t *atom = pointer;
    atom->value = rb_gc_location(atom->value);
    atom->updating_fiber = rb_gc_location(atom->updating_fiber);
    atom->updating_thread = rb_gc_location(atom->updating_thread);
}

static void
atom_free(void *pointer)
{
    atom_t *atom = pointer;
    pthread_mutex_destroy(&atom->lock);
    ruby_xfree(atom);
}

static size_t
atom_memsize(const void *pointer)
{
    return pointer ? sizeof(atom_t) : 0;
}

static const rb_data_type_t atom_type = {
    .wrap_struct_name = "Ractor::Containers::Atom",
    .function = {
        .dmark = atom_mark,
        .dfree = atom_free,
        .dsize = atom_memsize,
        .dcompact = atom_compact,
    },
    .flags = RUBY_TYPED_FROZEN_SHAREABLE,
};

static VALUE
atom_allocate(VALUE klass)
{
    atom_t *atom;
    VALUE object = TypedData_Make_Struct(klass, atom_t, &atom_type, atom);
    pthread_mutex_init(&atom->lock, NULL);
    atom->value = Qnil;
    atom->waiters = NULL;
    atom->version = 0;
    atom->compare_by_identity = false;
    atom->updating = false;
    atom->updating_fiber = Qnil;
    atom->updating_thread = Qnil;
    atom->initialized = false;
    return object;
}

static atom_t *
get_atom(VALUE self)
{
    atom_t *atom;
    TypedData_Get_Struct(self, atom_t, &atom_type, atom);
    if (!atom->initialized) rb_raise(rb_eRuntimeError, "uninitialized Atom");
    return atom;
}

/* Called with atom->lock held. Raising releases the short native mutex so the
 * reservation owner's ensure handler can clear it normally. */
static void
atom_check_update_wait_locked(atom_t *atom)
{
    VALUE current_fiber = rb_fiber_current();

    if (atom->updating_fiber == current_fiber) {
        pthread_mutex_unlock(&atom->lock);
        rb_raise(rb_eThreadError, "deadlock; recursive atom access during an update");
    }
    if (atom->updating_thread == rb_thread_current() &&
        NIL_P(rb_fiber_scheduler_current())) {
        pthread_mutex_unlock(&atom->lock);
        rb_raise(
            rb_eThreadError,
            "deadlock; atom update is owned by another unscheduled fiber"
        );
    }
}

static void
atom_begin_update_locked(atom_t *atom)
{
    atom->updating = true;
    atom->updating_fiber = rb_fiber_current();
    atom->updating_thread = rb_thread_current();
}

static void
atom_lock_for_update(atom_t *atom)
{
    atom_timeout_t timeout = {.finite = false, .deadline = 0};

    for (;;) {
        pthread_mutex_lock(&atom->lock);
        if (!atom->updating) return;
        atom_check_update_wait_locked(atom);
        (void)atom_wait_once(atom, &timeout);
    }
}

static VALUE
atom_extract_timeout(int argc, VALUE *argv, const char *format, VALUE *argument)
{
    VALUE keywords = Qnil;
    VALUE timeout = Qnil;
    ID keyword_ids[] = {rb_intern("timeout")};
    VALUE keyword_values[1];

    if (argument) rb_scan_args(argc, argv, format, argument, &keywords);
    else rb_scan_args(argc, argv, format, &keywords);
    if (!NIL_P(keywords)) {
        rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);
        if (keyword_values[0] != Qundef) timeout = keyword_values[0];
    }
    return timeout;
}

typedef struct {
    atom_t *atom;
    atom_waiter_t waiter;
    atom_timeout_t *timeout;
} atom_wait_context_t;

static bool
atom_wait_for_descriptor(int fd, atom_timeout_t *timeout)
{
    VALUE wait_timeout = Qnil;
    if (timeout->finite) {
        double remaining = timeout->deadline - atom_monotonic_now();
        if (remaining <= 0) return false;
        wait_timeout = DBL2NUM(remaining);
    }
    VALUE io = rb_io_open_descriptor(
        rb_cIO,
        fd,
        FMODE_READABLE | FMODE_EXTERNAL,
        Qnil,
        Qnil,
        NULL
    );
    VALUE result = rb_io_wait(io, INT2NUM(RUBY_IO_READABLE), wait_timeout);
    RB_GC_GUARD(io);
    return RTEST(result);
}

static VALUE
atom_wait_body(VALUE opaque)
{
    atom_wait_context_t *context = (atom_wait_context_t *)opaque;
    return atom_wait_for_descriptor(context->waiter.read_fd, context->timeout) ? Qtrue : Qfalse;
}

static VALUE
atom_wait_cleanup(VALUE opaque)
{
    atom_wait_context_t *context = (atom_wait_context_t *)opaque;
    atom_waiter_t **link;

    pthread_mutex_lock(&context->atom->lock);
    for (link = &context->atom->waiters; *link; link = &(*link)->next) {
        if (*link == &context->waiter) {
            *link = context->waiter.next;
            break;
        }
    }
    pthread_mutex_unlock(&context->atom->lock);
    close(context->waiter.read_fd);
    close(context->waiter.write_fd);
    return Qnil;
}

/* Called with atom->lock held and always returns with it released. */
static bool
atom_wait_once(atom_t *atom, atom_timeout_t *timeout)
{
    int descriptors[2];
    if (pipe(descriptors) != 0) {
        pthread_mutex_unlock(&atom->lock);
        rb_sys_fail("pipe");
    }
    atom_set_fd_flags(descriptors[0]);
    atom_set_fd_flags(descriptors[1]);

    atom_wait_context_t context = {
        .atom = atom,
        .waiter = {
            .read_fd = descriptors[0],
            .write_fd = descriptors[1],
            .notified = false,
            .next = atom->waiters,
        },
        .timeout = timeout,
    };
    atom->waiters = &context.waiter;
    pthread_mutex_unlock(&atom->lock);
    return RTEST(rb_ensure(atom_wait_body, (VALUE)&context, atom_wait_cleanup, (VALUE)&context));
}

/* Returns with atom->lock held on success and released on timeout. */
static bool
atom_lock_for_update_with_timeout(atom_t *atom, atom_timeout_t *timeout)
{
    for (;;) {
        pthread_mutex_lock(&atom->lock);
        if (!atom->updating) return true;
        atom_check_update_wait_locked(atom);
        if (!atom_wait_once(atom, timeout)) return false;
    }
}

static VALUE
atom_timeout_result(void)
{
    return rb_block_given_p() ? rb_yield_values(0) : Qnil;
}

static VALUE
atom_initialize(int argc, VALUE *argv, VALUE self)
{
    VALUE value = Qnil;
    VALUE keywords = Qnil;
    VALUE identity = Qundef;
    ID keyword_ids[] = {rb_intern("compare_by_identity")};
    VALUE keyword_values[1];
    atom_t *atom;

    rb_scan_args(argc, argv, "01:", &value, &keywords);
    if (!NIL_P(keywords)) {
        rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);
        identity = keyword_values[0];
    }

    TypedData_Get_Struct(self, atom_t, &atom_type, atom);
    if (atom->initialized) rb_raise(rb_eRuntimeError, "Atom is already initialized");
    containers_check_shareable(value);
    atom->value = value;
    atom->compare_by_identity = identity == Qundef ? false : containers_strict_bool(identity, "compare_by_identity");
    atom->initialized = true;
    containers_finish_initialization(self);
    return self;
}

static VALUE
atom_value(VALUE self)
{
    atom_t *atom = get_atom(self);
    VALUE value;
    pthread_mutex_lock(&atom->lock);
    value = atom->value;
    pthread_mutex_unlock(&atom->lock);
    return value;
}

static VALUE
atom_set_value(VALUE self, VALUE value)
{
    atom_t *atom = get_atom(self);
    containers_check_shareable(value);
    atom_lock_for_update(atom);
    atom->value = value;
    atom_changed(atom);
    pthread_mutex_unlock(&atom->lock);
    return value;
}

static VALUE
atom_get(int argc, VALUE *argv, VALUE self)
{
    atom_t *atom = get_atom(self);
    atom_timeout_t timeout = atom_parse_timeout(atom_extract_timeout(argc, argv, "0:", NULL));

    for (;;) {
        pthread_mutex_lock(&atom->lock);
        if (!atom->updating) {
            VALUE value = atom->value;
            pthread_mutex_unlock(&atom->lock);
            return value;
        }
        atom_check_update_wait_locked(atom);
        if (!atom_wait_once(atom, &timeout)) return atom_timeout_result();
    }
}

static VALUE
atom_store(int argc, VALUE *argv, VALUE self)
{
    VALUE value;
    atom_t *atom = get_atom(self);
    VALUE timeout_value = atom_extract_timeout(argc, argv, "1:", &value);
    containers_check_shareable(value);
    atom_timeout_t timeout = atom_parse_timeout(timeout_value);

    for (;;) {
        pthread_mutex_lock(&atom->lock);
        if (!atom->updating) {
            atom->value = value;
            atom_changed(atom);
            pthread_mutex_unlock(&atom->lock);
            return value;
        }
        atom_check_update_wait_locked(atom);
        if (!atom_wait_once(atom, &timeout)) return atom_timeout_result();
    }
}

static VALUE
atom_swap(int argc, VALUE *argv, VALUE self)
{
    VALUE value;
    atom_t *atom = get_atom(self);
    VALUE timeout_value = atom_extract_timeout(argc, argv, "1:", &value);
    containers_check_shareable(value);
    atom_timeout_t timeout = atom_parse_timeout(timeout_value);

    for (;;) {
        pthread_mutex_lock(&atom->lock);
        if (!atom->updating) {
            VALUE previous = atom->value;
            atom->value = value;
            atom_changed(atom);
            pthread_mutex_unlock(&atom->lock);
            return previous;
        }
        atom_check_update_wait_locked(atom);
        if (!atom_wait_once(atom, &timeout)) return atom_timeout_result();
    }
}

typedef struct {
    atom_t *atom;
    VALUE current;
    VALUE argument;
    bool identity;
    bool complete;
} atom_operation_t;

static VALUE
atom_operation_cleanup(VALUE opaque)
{
    atom_operation_t *operation = (atom_operation_t *)opaque;
    if (!operation->complete) {
        pthread_mutex_lock(&operation->atom->lock);
        atom_finished_update(operation->atom, false);
        pthread_mutex_unlock(&operation->atom->lock);
    }
    return Qnil;
}

static VALUE
atom_store_body(VALUE opaque)
{
    atom_operation_t *operation = (atom_operation_t *)opaque;
    VALUE result = rb_yield_values(0);
    containers_check_shareable(result);
    pthread_mutex_lock(&operation->atom->lock);
    operation->atom->value = result;
    atom_finished_update(operation->atom, true);
    pthread_mutex_unlock(&operation->atom->lock);
    operation->complete = true;
    return result;
}

static VALUE
atom_store_if_absent(int argc, VALUE *argv, VALUE self)
{
    atom_t *atom = get_atom(self);
    atom_operation_t operation = {.atom = atom, .complete = false};
    atom_timeout_t timeout = atom_parse_timeout(atom_extract_timeout(argc, argv, "0:", NULL));

    rb_need_block();
    if (!atom_lock_for_update_with_timeout(atom, &timeout)) return Qnil;
    if (!NIL_P(atom->value)) {
        VALUE value = atom->value;
        pthread_mutex_unlock(&atom->lock);
        return value;
    }
    atom_begin_update_locked(atom);
    pthread_mutex_unlock(&atom->lock);
    return rb_ensure(atom_store_body, (VALUE)&operation, atom_operation_cleanup, (VALUE)&operation);
}

typedef struct {
    atom_t *atom;
    VALUE current;
    VALUE expected;
    VALUE replacement;
    bool identity;
    bool complete;
} atom_cas_t;

static VALUE
atom_cas_cleanup(VALUE opaque)
{
    atom_cas_t *operation = (atom_cas_t *)opaque;
    if (!operation->complete) {
        pthread_mutex_lock(&operation->atom->lock);
        atom_finished_update(operation->atom, false);
        pthread_mutex_unlock(&operation->atom->lock);
    }
    return Qnil;
}

static VALUE
atom_cas_body(VALUE opaque)
{
    atom_cas_t *operation = (atom_cas_t *)opaque;
    bool matches = operation->identity
        ? operation->current == operation->expected
        : RTEST(rb_equal(operation->current, operation->expected));

    pthread_mutex_lock(&operation->atom->lock);
    if (matches) operation->atom->value = operation->replacement;
    atom_finished_update(operation->atom, matches);
    pthread_mutex_unlock(&operation->atom->lock);
    operation->complete = true;
    return matches ? Qtrue : Qfalse;
}

static VALUE
atom_compare_and_set(int argc, VALUE *argv, VALUE self)
{
    VALUE expected;
    VALUE replacement;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    rb_scan_args(argc, argv, "2:", &expected, &replacement, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    atom_t *atom = get_atom(self);
    atom_cas_t operation;
    containers_check_shareable(expected);
    containers_check_shareable(replacement);
    atom_timeout_t timeout = atom_parse_timeout(
        keyword_values[0] == Qundef ? Qnil : keyword_values[0]
    );

    if (!atom_lock_for_update_with_timeout(atom, &timeout)) return Qfalse;
    operation.atom = atom;
    operation.current = atom->value;
    operation.expected = expected;
    operation.replacement = replacement;
    operation.identity = atom->compare_by_identity;
    operation.complete = false;
    atom_begin_update_locked(atom);
    pthread_mutex_unlock(&atom->lock);

    return rb_ensure(atom_cas_body, (VALUE)&operation, atom_cas_cleanup, (VALUE)&operation);
}

static VALUE
atom_update_body(VALUE opaque)
{
    atom_operation_t *operation = (atom_operation_t *)opaque;
    VALUE result = rb_yield(operation->current);
    containers_check_shareable(result);
    pthread_mutex_lock(&operation->atom->lock);
    operation->atom->value = result;
    atom_finished_update(operation->atom, true);
    pthread_mutex_unlock(&operation->atom->lock);
    operation->complete = true;
    return result;
}

static VALUE
atom_update(int argc, VALUE *argv, VALUE self)
{
    atom_t *atom = get_atom(self);
    atom_operation_t operation = {.atom = atom, .complete = false};
    atom_timeout_t timeout = atom_parse_timeout(atom_extract_timeout(argc, argv, "0:", NULL));
    rb_need_block();

    if (!atom_lock_for_update_with_timeout(atom, &timeout)) return Qnil;
    operation.current = atom->value;
    atom_begin_update_locked(atom);
    pthread_mutex_unlock(&atom->lock);

    return rb_ensure(atom_update_body, (VALUE)&operation, atom_operation_cleanup, (VALUE)&operation);
}

static VALUE
atom_upsert(int argc, VALUE *argv, VALUE self)
{
    VALUE initial;
    atom_t *atom = get_atom(self);
    atom_operation_t operation = {.atom = atom, .complete = false};
    atom_timeout_t timeout = atom_parse_timeout(atom_extract_timeout(argc, argv, "1:", &initial));
    containers_check_shareable(initial);
    rb_need_block();

    if (!atom_lock_for_update_with_timeout(atom, &timeout)) return Qnil;
    if (NIL_P(atom->value)) {
        atom->value = initial;
        atom_changed(atom);
        pthread_mutex_unlock(&atom->lock);
        return initial;
    }
    operation.current = atom->value;
    atom_begin_update_locked(atom);
    pthread_mutex_unlock(&atom->lock);

    return rb_ensure(atom_update_body, (VALUE)&operation, atom_operation_cleanup, (VALUE)&operation);
}

static bool
atom_values_equal(atom_t *atom, VALUE left, VALUE right)
{
    return atom->compare_by_identity ? left == right : RTEST(rb_equal(left, right));
}

static VALUE
atom_wait_until_changed(int argc, VALUE *argv, VALUE self)
{
    VALUE expected;
    atom_t *atom = get_atom(self);
    VALUE timeout_value = atom_extract_timeout(argc, argv, "1:", &expected);
    containers_check_shareable(expected);
    atom_timeout_t timeout = atom_parse_timeout(timeout_value);

    for (;;) {
        VALUE current;
        uint64_t version;
        pthread_mutex_lock(&atom->lock);
        current = atom->value;
        version = atom->version;
        pthread_mutex_unlock(&atom->lock);

        if (!atom_values_equal(atom, current, expected)) return current;

        pthread_mutex_lock(&atom->lock);
        if (atom->version != version) {
            pthread_mutex_unlock(&atom->lock);
            continue;
        }
        if (atom->updating) atom_check_update_wait_locked(atom);
        if (!atom_wait_once(atom, &timeout)) return atom_timeout_result();
    }
}

static VALUE
atom_wait_until_non_nil(int argc, VALUE *argv, VALUE self)
{
    atom_t *atom = get_atom(self);
    atom_timeout_t timeout = atom_parse_timeout(atom_extract_timeout(argc, argv, "0:", NULL));

    for (;;) {
        pthread_mutex_lock(&atom->lock);
        if (!NIL_P(atom->value)) {
            VALUE current = atom->value;
            pthread_mutex_unlock(&atom->lock);
            return current;
        }
        if (atom->updating) atom_check_update_wait_locked(atom);
        if (!atom_wait_once(atom, &timeout)) return atom_timeout_result();
    }
}

static VALUE
atom_compare_by_identity_p(VALUE self)
{
    return get_atom(self)->compare_by_identity ? Qtrue : Qfalse;
}


void
containers_init_atom(VALUE namespace)
{
    cAtom = rb_define_class_under(namespace, "Atom", rb_cObject);
    rb_define_alloc_func(cAtom, atom_allocate);
    rb_define_method(cAtom, "initialize", atom_initialize, -1);
    rb_define_method(cAtom, "value", atom_value, 0);
    rb_define_method(cAtom, "value=", atom_set_value, 1);
    rb_define_method(cAtom, "get", atom_get, -1);
    rb_define_method(cAtom, "store", atom_store, -1);
    rb_define_method(cAtom, "swap", atom_swap, -1);
    rb_define_method(cAtom, "store_if_absent", atom_store_if_absent, -1);
    rb_define_method(cAtom, "compare_and_set", atom_compare_and_set, -1);
    rb_define_method(cAtom, "update", atom_update, -1);
    rb_define_method(cAtom, "upsert", atom_upsert, -1);
    rb_define_method(cAtom, "wait_until_changed", atom_wait_until_changed, -1);
    rb_define_method(cAtom, "wait_until_non_nil", atom_wait_until_non_nil, -1);
    rb_define_method(cAtom, "compare_by_identity?", atom_compare_by_identity_p, 0);
}
