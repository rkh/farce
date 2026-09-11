#include "containers.h"
#include "ruby/io.h"
#include "unshared_wait.h"

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

static VALUE cQueue;
static VALUE eClosedQueueError;
static ID id_timeout;

#define QUEUE_INITIAL_CAPACITY 16


typedef struct {
    int read_fd;
    int write_fd;
    bool set;
} readiness_signal_t;

typedef struct {
    pthread_mutex_t lock;
    VALUE *values;
    size_t storage_capacity;
    size_t limit;
    size_t size;
    size_t head;
    size_t tail;
    size_t pop_waiters;
    size_t push_waiters;
    readiness_signal_t can_pop;
    readiness_signal_t can_push;
    farce_unshared_wait_list_t unshared_pop_waiters;
    farce_unshared_wait_list_t unshared_push_waiters;
    bool bounded;
    bool closed;
    bool initialized;
    bool shared;
    bool unshared_fiber_io;
    bool unshared_notifications_needed;
} queue_t;

static void
set_fd_flags(int fd)
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

static bool
readiness_initialize(readiness_signal_t *signal)
{
    int descriptors[2];
    if (pipe(descriptors) != 0) return false;
    signal->read_fd = descriptors[0];
    signal->write_fd = descriptors[1];
    signal->set = false;
    set_fd_flags(signal->read_fd);
    set_fd_flags(signal->write_fd);
    return true;
}

static void
readiness_close(readiness_signal_t *signal)
{
    if (signal->read_fd >= 0) close(signal->read_fd);
    if (signal->write_fd >= 0) close(signal->write_fd);
    signal->read_fd = -1;
    signal->write_fd = -1;
    signal->set = false;
}

static void
readiness_set(readiness_signal_t *signal, bool desired)
{
    unsigned char byte = 1;
    ssize_t result;
    if (desired == signal->set) return;
    if (desired) {
        do {
            result = write(signal->write_fd, &byte, 1);
        } while (result < 0 && errno == EINTR);
        if (result == 1 || (result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))) {
            signal->set = true;
        }
    }
    else {
        do {
            result = read(signal->read_fd, &byte, 1);
        } while (result < 0 && errno == EINTR);
        if (result == 1 || (result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))) {
            signal->set = false;
        }
    }
}

static void
queue_update_readiness(queue_t *queue)
{
    if (!queue->shared) {
        if (!queue->unshared_notifications_needed) return;
        if (queue->closed || queue->size > 0) {
            farce_unshared_wait_notify_all(&queue->unshared_pop_waiters);
        }
        if (queue->closed || !queue->bounded || queue->size < queue->limit) {
            farce_unshared_wait_notify_all(&queue->unshared_push_waiters);
        }
    }
    readiness_set(
        &queue->can_pop,
        queue->pop_waiters > 0 && (queue->closed || queue->size > 0)
    );
    readiness_set(
        &queue->can_push,
        queue->push_waiters > 0 &&
            (queue->closed || !queue->bounded || queue->size < queue->limit)
    );
    if (!queue->shared) {
        /* Keep the slow path until both waiter mechanisms and every pending
         * readiness byte have drained. Interrupted direct waits may leave the
         * flag set, which is harmless and corrected by the next mutation. */
        queue->unshared_notifications_needed = queue->pop_waiters || queue->push_waiters ||
            queue->unshared_pop_waiters.count || queue->unshared_push_waiters.count ||
            queue->can_pop.set || queue->can_push.set;
    }
}

static void
queue_mark(void *pointer)
{
    queue_t *queue = pointer;
    farce_unshared_wait_mark(&queue->unshared_pop_waiters);
    farce_unshared_wait_mark(&queue->unshared_push_waiters);
    if (!queue->values) return;
    size_t index = queue->head;
    for (size_t remaining = queue->size; remaining > 0; remaining--) {
        rb_gc_mark_movable(queue->values[index]);
        if (++index == queue->storage_capacity) index = 0;
    }
}

static void
queue_compact(void *pointer)
{
    queue_t *queue = pointer;
    if (!queue->values) return;
    size_t index = queue->head;
    for (size_t remaining = queue->size; remaining > 0; remaining--) {
        queue->values[index] = rb_gc_location(queue->values[index]);
        if (++index == queue->storage_capacity) index = 0;
    }
}

static void
queue_free(void *pointer)
{
    queue_t *queue = pointer;
    if (queue->shared) pthread_mutex_destroy(&queue->lock);
    free(queue->values);
    if (queue->can_pop.read_fd >= 0) close(queue->can_pop.read_fd);
    if (queue->can_pop.write_fd >= 0) close(queue->can_pop.write_fd);
    if (queue->can_push.read_fd >= 0) close(queue->can_push.read_fd);
    if (queue->can_push.write_fd >= 0) close(queue->can_push.write_fd);
    ruby_xfree(queue);
}

static size_t
queue_memsize(const void *pointer)
{
    const queue_t *queue = pointer;
    return queue ? sizeof(queue_t) + queue->storage_capacity * sizeof(VALUE) : 0;
}

static const rb_data_type_t queue_type = {
    .wrap_struct_name = "Ractor::Containers::Queue",
    .function = {
        .dmark = queue_mark,
        .dfree = queue_free,
        .dsize = queue_memsize,
        .dcompact = queue_compact,
    },
    .flags = RUBY_TYPED_FROZEN_SHAREABLE,
};

static const rb_data_type_t unshared_queue_type = {
    .wrap_struct_name = "Farce::Internal::UnsharedQueue",
    .function = {
        .dmark = queue_mark,
        .dfree = queue_free,
        .dsize = queue_memsize,
        .dcompact = queue_compact,
    },
    .parent = &queue_type,
};

/* Unshared queues are confined to one Ractor. These critical sections call no
 * Ruby code and retain the GVL. Waiting releases it only after leaving them. */
static inline void queue_lock(queue_t *queue)
{
    if (queue->shared) pthread_mutex_lock(&queue->lock);
}

static inline void queue_unlock(queue_t *queue)
{
    if (queue->shared) pthread_mutex_unlock(&queue->lock);
}

static VALUE
queue_allocate_type(VALUE klass, bool shared)
{
    queue_t *queue;
    VALUE object = TypedData_Make_Struct(klass, queue_t, shared ? &queue_type : &unshared_queue_type, queue);
    if (shared) pthread_mutex_init(&queue->lock, NULL);
    queue->values = NULL;
    queue->storage_capacity = 0;
    queue->limit = 0;
    queue->size = 0;
    queue->head = 0;
    queue->tail = 0;
    queue->pop_waiters = 0;
    queue->push_waiters = 0;
    queue->can_pop = (readiness_signal_t){.read_fd = -1, .write_fd = -1, .set = false};
    queue->can_push = (readiness_signal_t){.read_fd = -1, .write_fd = -1, .set = false};
    queue->unshared_pop_waiters = (farce_unshared_wait_list_t){0};
    queue->unshared_push_waiters = (farce_unshared_wait_list_t){0};
    queue->bounded = true;
    queue->closed = false;
    queue->initialized = false;
    queue->shared = shared;
    queue->unshared_notifications_needed = false;
    return object;
}

static VALUE queue_allocate(VALUE klass) { return queue_allocate_type(klass, true); }
static VALUE unshared_queue_allocate(VALUE klass) { return queue_allocate_type(klass, false); }

static queue_t *
get_queue(VALUE self)
{
    queue_t *queue;
    TypedData_Get_Struct(self, queue_t, &queue_type, queue);
    if (!queue->initialized) rb_raise(rb_eRuntimeError, "uninitialized Queue");
    return queue;
}

static VALUE
queue_initialize(int argc, VALUE *argv, VALUE self)
{
    VALUE keywords = Qnil;
    VALUE capacity_value = Qundef;
    ID keyword_ids[] = {rb_intern("capacity"), rb_intern("fiber_wait")};
    VALUE keyword_values[2] = {Qundef, Qundef};
    queue_t *queue;
    TypedData_Get_Struct(self, queue_t, &queue_type, queue);
    rb_scan_args(argc, argv, "0:", &keywords);
    if (!NIL_P(keywords)) {
        rb_get_kwargs(keywords, keyword_ids, 0, queue->shared ? 1 : 2, keyword_values);
        capacity_value = keyword_values[0];
    }
    if (queue->initialized) rb_raise(rb_eRuntimeError, "Queue is already initialized");
    bool fiber_io = containers_unshared_fiber_io(keyword_values[1]);

    if (NIL_P(capacity_value)) {
        queue->bounded = false;
        queue->storage_capacity = QUEUE_INITIAL_CAPACITY;
    }
    else {
        VALUE converted = capacity_value == Qundef ? INT2FIX(1024) : rb_to_int(capacity_value);
        long long capacity = NUM2LL(converted);
        if (capacity <= 0) rb_raise(rb_eArgError, "capacity must be positive or nil");
        if ((unsigned long long)capacity > SIZE_MAX / sizeof(VALUE)) {
            rb_raise(rb_eArgError, "capacity is too large");
        }
        queue->bounded = true;
        queue->limit = (size_t)capacity;
        queue->storage_capacity = queue->limit;
    }

    queue->values = calloc(queue->storage_capacity, sizeof(VALUE));
    if (!queue->values) rb_memerror();
    queue->unshared_fiber_io = fiber_io;
    queue->initialized = true;
    if (queue->shared) containers_finish_initialization(self);
    else rb_obj_freeze(self);
    return self;
}

typedef struct {
    bool finite;
    double deadline;
} queue_timeout_t;

static double
monotonic_now(void)
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

static queue_timeout_t
parse_timeout(VALUE timeout)
{
    queue_timeout_t parsed = {.finite = false, .deadline = 0};
    if (NIL_P(timeout)) return parsed;
    double seconds = NUM2DBL(timeout);
    if (!isfinite(seconds) || seconds < 0) {
        rb_raise(rb_eArgError, "timeout must be a finite, non-negative number or nil");
    }
    parsed.finite = true;
    /* A zero deadline denotes polling and never needs to read the clock. */
    parsed.deadline = seconds == 0 ? 0 : monotonic_now() + seconds;
    return parsed;
}

static VALUE
extract_timeout(int argc, VALUE *argv)
{
    if (argc == 0) return Qnil;
    /* rb_scan_args copies keyword hashes for rb_get_kwargs to consume. The
     * common single-keyword case can read the original hash without copying. */
    if (argc == 1 && rb_keyword_given_p() && RHASH_SIZE(argv[0]) == 1) {
        VALUE timeout = rb_hash_lookup2(argv[0], ID2SYM(id_timeout), Qundef);
        if (timeout != Qundef) return timeout;
    }
    VALUE keywords = Qnil;
    VALUE timeout = Qnil;
    ID keyword_ids[] = {rb_intern("timeout")};
    VALUE keyword_values[1];
    rb_scan_args(argc, argv, "0:", &keywords);
    if (!NIL_P(keywords)) {
        rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);
        if (keyword_values[0] != Qundef) timeout = keyword_values[0];
    }
    return timeout;
}

static VALUE
queue_wait_descriptor_body(VALUE opaque)
{
    VALUE *arguments = (VALUE *)opaque;
    return rb_io_wait(arguments[0], INT2NUM(RUBY_IO_READABLE), arguments[1]);
}

static VALUE
queue_wait_descriptor_cleanup(VALUE opaque)
{
    VALUE *arguments = (VALUE *)opaque;
    return rb_io_close(arguments[0]);
}

static bool
queue_wait_for_descriptor(int fd, queue_timeout_t *timeout)
{
    VALUE wait_timeout = Qnil;
    if (timeout->finite) {
        double remaining = timeout->deadline - monotonic_now();
        if (remaining <= 0) return false;
        wait_timeout = DBL2NUM(remaining);
    }
    VALUE arguments[] = {
        rb_io_open_descriptor(
            rb_cIO,
            fd,
            FMODE_READABLE | FMODE_EXTERNAL,
            Qnil,
            Qnil,
            NULL
        ),
        wait_timeout,
    };
    VALUE result = rb_ensure(
        queue_wait_descriptor_body,
        (VALUE)arguments,
        queue_wait_descriptor_cleanup,
        (VALUE)arguments
    );
    RB_GC_GUARD(arguments[0]);
    return RTEST(result);
}

typedef struct {
    queue_t *queue;
    readiness_signal_t *signal;
    size_t *waiter_count;
    queue_timeout_t *timeout;
    int wait_fd;
} queue_wait_context_t;

static VALUE
queue_wait_body(VALUE opaque)
{
    queue_wait_context_t *context = (queue_wait_context_t *)opaque;
    return queue_wait_for_descriptor(context->wait_fd, context->timeout) ? Qtrue : Qfalse;
}

static VALUE
queue_wait_cleanup(VALUE opaque)
{
    queue_wait_context_t *context = (queue_wait_context_t *)opaque;
    close(context->wait_fd);
    queue_lock(context->queue);
    (*context->waiter_count)--;
    queue_update_readiness(context->queue);
    if (context->queue->closed && *context->waiter_count == 0) {
        readiness_close(context->signal);
    }
    queue_unlock(context->queue);
    return Qnil;
}

/* Called with queue->lock held and always returns with it released. Registering
 * before the unlock closes the check-to-wait race with a producer or consumer. */
static bool
queue_wait(VALUE self, queue_t *queue, readiness_signal_t *signal, size_t *waiter_count, queue_timeout_t *timeout)
{
    if (timeout->finite && (timeout->deadline == 0 || timeout->deadline <= monotonic_now())) {
        queue_unlock(queue);
        return false;
    }
    if (!queue->shared) queue->unshared_notifications_needed = true;
    if (!queue->shared && (!queue->unshared_fiber_io || NIL_P(rb_fiber_scheduler_current()))) {
        farce_unshared_wait_list_t *list = signal == &queue->can_pop ?
            &queue->unshared_pop_waiters : &queue->unshared_push_waiters;
        return farce_unshared_wait(list, self, timeout->finite, timeout->deadline);
    }
    if (signal->read_fd < 0 && !readiness_initialize(signal)) {
        int error = errno;
        queue_unlock(queue);
        errno = error;
        rb_sys_fail("pipe");
    }
    /* Ruby 3.4 reports rb_io_close for an external wrapper to every waiter on
     * the same descriptor number. A duplicate observes the same readiness pipe
     * without letting one waiter's wrapper cleanup cancel its siblings. */
    int wait_fd = dup(signal->read_fd);
    if (wait_fd < 0) {
        int error = errno;
        queue_unlock(queue);
        errno = error;
        rb_sys_fail("dup");
    }
    set_fd_flags(wait_fd);
    queue_wait_context_t context = {
        .queue = queue,
        .signal = signal,
        .waiter_count = waiter_count,
        .timeout = timeout,
        .wait_fd = wait_fd,
    };
    (*waiter_count)++;
    queue_update_readiness(queue);
    queue_unlock(queue);
    return RTEST(rb_ensure(queue_wait_body, (VALUE)&context, queue_wait_cleanup, (VALUE)&context));
}

RBIMPL_ATTR_NORETURN()
static void
raise_queue_closed(void)
{
    rb_raise(eClosedQueueError, "queue is closed");
}

static VALUE
unshared_queue_fiber_wait(VALUE self)
{
    return ID2SYM(rb_intern(get_queue(self)->unshared_fiber_io ? "io" : "block"));
}

static VALUE
queue_capacity(VALUE self)
{
    queue_t *queue = get_queue(self);
    return queue->bounded ? SIZET2NUM(queue->limit) : Qnil;
}

/* Called with queue->lock held. The queue is unchanged if allocation fails. */
static bool
queue_grow(queue_t *queue)
{
    size_t current = queue->storage_capacity;
    if (current > SIZE_MAX / 2 || current * 2 > SIZE_MAX / sizeof(VALUE)) return false;

    size_t grown = current * 2;
    VALUE *values = calloc(grown, sizeof(VALUE));
    if (!values) return false;

    for (size_t index = 0; index < queue->size; index++) {
        values[index] = queue->values[(queue->head + index) % current];
    }
    free(queue->values);
    queue->values = values;
    queue->storage_capacity = grown;
    queue->head = 0;
    queue->tail = queue->size;
    return true;
}

static VALUE
queue_size(VALUE self)
{
    queue_t *queue = get_queue(self);
    size_t size;
    queue_lock(queue);
    size = queue->size;
    queue_unlock(queue);
    return SIZET2NUM(size);
}

static VALUE
queue_num_waiting(VALUE self)
{
    queue_t *queue = get_queue(self);
    size_t num_waiting;
    queue_lock(queue);
    num_waiting = queue->pop_waiters + queue->push_waiters +
        queue->unshared_pop_waiters.count + queue->unshared_push_waiters.count;
    queue_unlock(queue);
    return SIZET2NUM(num_waiting);
}

static VALUE
queue_clear(VALUE self)
{
    queue_t *queue = get_queue(self);
    queue_lock(queue);

    size_t index = queue->head;
    for (size_t remaining = queue->size; remaining > 0; remaining--) {
        queue->values[index] = Qnil;
        index++;
        if (index == queue->storage_capacity) index = 0;
    }
    queue->size = 0;
    queue->head = 0;
    queue->tail = 0;
    queue_update_readiness(queue);

    queue_unlock(queue);
    return self;
}

static VALUE
queue_closed_p(VALUE self)
{
    queue_t *queue = get_queue(self);
    bool closed;
    queue_lock(queue);
    closed = queue->closed;
    queue_unlock(queue);
    return closed ? Qtrue : Qfalse;
}

static VALUE
queue_close(VALUE self)
{
    queue_t *queue = get_queue(self);
    queue_lock(queue);
    if (!queue->closed) {
        queue->closed = true;
        queue_update_readiness(queue);
        if (queue->pop_waiters == 0) readiness_close(&queue->can_pop);
        if (queue->push_waiters == 0) readiness_close(&queue->can_push);
    }
    queue_unlock(queue);
    return self;
}

/* Internal hook for one-consumer RPC queues. Closing dormant readiness
 * descriptors keeps the Queue reusable while avoiding descriptor retention. */
static VALUE
queue_release_wait_descriptors(VALUE self)
{
    queue_t *queue = get_queue(self);
    queue_lock(queue);
    if (queue->pop_waiters == 0) readiness_close(&queue->can_pop);
    if (queue->push_waiters == 0) readiness_close(&queue->can_push);
    queue_unlock(queue);
    return self;
}

static VALUE
queue_pop_with_timeout(VALUE self, queue_t *queue, queue_timeout_t timeout)
{
    for (;;) {
        queue_lock(queue);
        if (queue->closed) {
            queue_unlock(queue);
            raise_queue_closed();
        }
        if (queue->size > 0) {
            VALUE value = queue->values[queue->head];
            queue->values[queue->head] = Qnil;
            if (++queue->head == queue->storage_capacity) queue->head = 0;
            queue->size--;
            queue_update_readiness(queue);
            queue_unlock(queue);
            return value;
        }
        if (!queue_wait(self, queue, &queue->can_pop, &queue->pop_waiters, &timeout)) {
            return rb_block_given_p() ? rb_yield_values(0) : Qnil;
        }
    }
}

static VALUE
queue_pop(int argc, VALUE *argv, VALUE self)
{
    queue_t *queue = get_queue(self);
    queue_timeout_t timeout = {.finite = false, .deadline = 0};
    if (argc > 0) timeout = parse_timeout(extract_timeout(argc, argv));
    return queue_pop_with_timeout(self, queue, timeout);
}

static VALUE
queue_try_pop(VALUE self)
{
    queue_timeout_t timeout = {.finite = true, .deadline = 0};
    return queue_pop_with_timeout(self, get_queue(self), timeout);
}

static VALUE
queue_push_with_timeout(VALUE self, queue_t *queue, VALUE value, queue_timeout_t timeout)
{
    for (;;) {
        queue_lock(queue);
        if (queue->closed) {
            queue_unlock(queue);
            raise_queue_closed();
        }
        if (!queue->bounded || queue->size < queue->limit) {
            if (queue->size == queue->storage_capacity && !queue_grow(queue)) {
                queue_unlock(queue);
                rb_memerror();
            }
            queue->values[queue->tail] = value;
            if (++queue->tail == queue->storage_capacity) queue->tail = 0;
            queue->size++;
            queue_update_readiness(queue);
            queue_unlock(queue);
            return Qtrue;
        }
        if (!queue_wait(self, queue, &queue->can_push, &queue->push_waiters, &timeout)) return Qfalse;
    }
}

static VALUE
queue_push(int argc, VALUE *argv, VALUE self)
{
    VALUE value;
    VALUE keywords = Qnil;
    VALUE timeout_value = Qnil;
    ID keyword_ids[] = {rb_intern("timeout")};
    VALUE keyword_values[1];
    if (argc == 1 && !rb_keyword_given_p()) {
        value = argv[0];
    }
    else if (argc == 2 && rb_keyword_given_p()) {
        value = argv[0];
        timeout_value = extract_timeout(1, argv + 1);
    }
    else {
        /* Preserve Ruby's positional-hash and keyword-only argument rules. */
        rb_scan_args(argc, argv, "1:", &value, &keywords);
        if (!NIL_P(keywords)) {
            rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);
            if (keyword_values[0] != Qundef) timeout_value = keyword_values[0];
        }
    }

    queue_t *queue = get_queue(self);
    if (queue->shared) containers_check_shareable(value);
    queue_timeout_t timeout = parse_timeout(timeout_value);
    return queue_push_with_timeout(self, queue, value, timeout);
}

static VALUE
queue_try_push(VALUE self, VALUE value)
{
    queue_t *queue = get_queue(self);
    if (queue->shared) containers_check_shareable(value);
    queue_timeout_t timeout = {.finite = true, .deadline = 0};
    return queue_push_with_timeout(self, queue, value, timeout);
}

static VALUE
queue_wait_pop(int argc, VALUE *argv, VALUE self)
{
    queue_t *queue = get_queue(self);
    queue_timeout_t timeout = parse_timeout(extract_timeout(argc, argv));
    for (;;) {
        queue_lock(queue);
        if (queue->closed) {
            queue_unlock(queue);
            raise_queue_closed();
        }
        bool ready = queue->size > 0;
        if (ready) {
            queue_unlock(queue);
            return Qtrue;
        }
        if (!queue_wait(self, queue, &queue->can_pop, &queue->pop_waiters, &timeout)) return Qfalse;
    }
}

static VALUE
queue_wait_push(int argc, VALUE *argv, VALUE self)
{
    queue_t *queue = get_queue(self);
    queue_timeout_t timeout = parse_timeout(extract_timeout(argc, argv));
    for (;;) {
        queue_lock(queue);
        if (queue->closed) {
            queue_unlock(queue);
            raise_queue_closed();
        }
        bool ready = !queue->bounded || queue->size < queue->limit;
        if (ready) {
            queue_unlock(queue);
            return Qtrue;
        }
        if (!queue_wait(self, queue, &queue->can_push, &queue->push_waiters, &timeout)) return Qfalse;
    }
}


void
containers_init_queue(VALUE namespace)
{
    id_timeout = rb_intern("timeout");
    eClosedQueueError = rb_const_get(rb_cObject, rb_intern("ClosedQueueError"));
    cQueue = rb_define_class_under(namespace, "Queue", rb_cObject);
    rb_define_alloc_func(cQueue, queue_allocate);
    VALUE unshared = rb_define_class_under(namespace, "UnsharedQueue", cQueue);
    rb_define_alloc_func(unshared, unshared_queue_allocate);
    rb_define_method(unshared, "fiber_wait", unshared_queue_fiber_wait, 0);
    rb_define_method(cQueue, "initialize", queue_initialize, -1);
    rb_define_method(cQueue, "capacity", queue_capacity, 0);
    rb_define_method(cQueue, "size", queue_size, 0);
    rb_define_method(cQueue, "num_waiting", queue_num_waiting, 0);
    rb_define_method(cQueue, "clear", queue_clear, 0);
    rb_define_method(cQueue, "pop", queue_pop, -1);
    rb_define_method(cQueue, "try_pop", queue_try_pop, 0);
    rb_define_method(cQueue, "push", queue_push, -1);
    rb_define_method(cQueue, "try_push", queue_try_push, 1);
    rb_define_method(cQueue, "wait_pop", queue_wait_pop, -1);
    rb_define_method(cQueue, "wait_push", queue_wait_push, -1);
    rb_define_method(cQueue, "close", queue_close, 0);
    rb_define_method(cQueue, "closed?", queue_closed_p, 0);
    rb_define_private_method(cQueue, "__release_wait_descriptors__", queue_release_wait_descriptors, 0);
}
