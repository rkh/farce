#include "containers.h"
#include "ruby/io.h"

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

static VALUE cQueue;
static VALUE eClosedQueueError;

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
    bool bounded;
    bool closed;
    bool initialized;
} queue_t;

static void
set_fd_flags(int fd)
{
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) (void)fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    flags = fcntl(fd, F_GETFD, 0);
    if (flags >= 0) (void)fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
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
    readiness_set(
        &queue->can_pop,
        queue->pop_waiters > 0 && (queue->closed || queue->size > 0)
    );
    readiness_set(
        &queue->can_push,
        queue->push_waiters > 0 &&
            (queue->closed || !queue->bounded || queue->size < queue->limit)
    );
}

static void
queue_mark(void *pointer)
{
    queue_t *queue = pointer;
    if (!queue->values) return;
    for (size_t index = 0; index < queue->storage_capacity; index++) {
        rb_gc_mark_movable(queue->values[index]);
    }
}

static void
queue_compact(void *pointer)
{
    queue_t *queue = pointer;
    if (!queue->values) return;
    for (size_t index = 0; index < queue->storage_capacity; index++) {
        queue->values[index] = rb_gc_location(queue->values[index]);
    }
}

static void
queue_free(void *pointer)
{
    queue_t *queue = pointer;
    pthread_mutex_destroy(&queue->lock);
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

static VALUE
queue_allocate(VALUE klass)
{
    queue_t *queue;
    VALUE object = TypedData_Make_Struct(klass, queue_t, &queue_type, queue);
    pthread_mutex_init(&queue->lock, NULL);
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
    queue->bounded = true;
    queue->closed = false;
    queue->initialized = false;
    return object;
}

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
    ID keyword_ids[] = {rb_intern("capacity")};
    VALUE keyword_values[1];
    queue_t *queue;
    rb_scan_args(argc, argv, "0:", &keywords);
    if (!NIL_P(keywords)) {
        rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);
        capacity_value = keyword_values[0];
    }
    TypedData_Get_Struct(self, queue_t, &queue_type, queue);
    if (queue->initialized) rb_raise(rb_eRuntimeError, "Queue is already initialized");

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
    queue->initialized = true;
    containers_finish_initialization(self);
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
    parsed.deadline = monotonic_now() + seconds;
    return parsed;
}

static VALUE
extract_timeout(int argc, VALUE *argv)
{
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

static bool
queue_wait_for_descriptor(int fd, queue_timeout_t *timeout)
{
    VALUE wait_timeout = Qnil;
    if (timeout->finite) {
        double remaining = timeout->deadline - monotonic_now();
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

typedef struct {
    queue_t *queue;
    readiness_signal_t *signal;
    size_t *waiter_count;
    queue_timeout_t *timeout;
} queue_wait_context_t;

static VALUE
queue_wait_body(VALUE opaque)
{
    queue_wait_context_t *context = (queue_wait_context_t *)opaque;
    return queue_wait_for_descriptor(context->signal->read_fd, context->timeout) ? Qtrue : Qfalse;
}

static VALUE
queue_wait_cleanup(VALUE opaque)
{
    queue_wait_context_t *context = (queue_wait_context_t *)opaque;
    pthread_mutex_lock(&context->queue->lock);
    (*context->waiter_count)--;
    queue_update_readiness(context->queue);
    if (context->queue->closed && *context->waiter_count == 0) {
        readiness_close(context->signal);
    }
    pthread_mutex_unlock(&context->queue->lock);
    return Qnil;
}

/* Called with queue->lock held and always returns with it released. Registering
 * before the unlock closes the check-to-wait race with a producer or consumer. */
static bool
queue_wait(queue_t *queue, readiness_signal_t *signal, size_t *waiter_count, queue_timeout_t *timeout)
{
    if (timeout->finite && timeout->deadline <= monotonic_now()) {
        pthread_mutex_unlock(&queue->lock);
        return false;
    }
    if (signal->read_fd < 0 && !readiness_initialize(signal)) {
        int error = errno;
        pthread_mutex_unlock(&queue->lock);
        errno = error;
        rb_sys_fail("pipe");
    }
    queue_wait_context_t context = {
        .queue = queue,
        .signal = signal,
        .waiter_count = waiter_count,
        .timeout = timeout,
    };
    (*waiter_count)++;
    queue_update_readiness(queue);
    pthread_mutex_unlock(&queue->lock);
    return RTEST(rb_ensure(queue_wait_body, (VALUE)&context, queue_wait_cleanup, (VALUE)&context));
}

RBIMPL_ATTR_NORETURN()
static void
raise_queue_closed(void)
{
    rb_raise(eClosedQueueError, "queue is closed");
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
    pthread_mutex_lock(&queue->lock);
    size = queue->size;
    pthread_mutex_unlock(&queue->lock);
    return SIZET2NUM(size);
}

static VALUE
queue_clear(VALUE self)
{
    queue_t *queue = get_queue(self);
    pthread_mutex_lock(&queue->lock);

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

    pthread_mutex_unlock(&queue->lock);
    return self;
}

static VALUE
queue_closed_p(VALUE self)
{
    queue_t *queue = get_queue(self);
    bool closed;
    pthread_mutex_lock(&queue->lock);
    closed = queue->closed;
    pthread_mutex_unlock(&queue->lock);
    return closed ? Qtrue : Qfalse;
}

static VALUE
queue_close(VALUE self)
{
    queue_t *queue = get_queue(self);
    pthread_mutex_lock(&queue->lock);
    if (!queue->closed) {
        queue->closed = true;
        queue_update_readiness(queue);
        if (queue->pop_waiters == 0) readiness_close(&queue->can_pop);
        if (queue->push_waiters == 0) readiness_close(&queue->can_push);
    }
    pthread_mutex_unlock(&queue->lock);
    return self;
}

/* Internal hook for one-consumer RPC queues. Closing dormant readiness
 * descriptors keeps the Queue reusable while avoiding descriptor retention. */
static VALUE
queue_release_wait_descriptors(VALUE self)
{
    queue_t *queue = get_queue(self);
    pthread_mutex_lock(&queue->lock);
    if (queue->pop_waiters == 0) readiness_close(&queue->can_pop);
    if (queue->push_waiters == 0) readiness_close(&queue->can_push);
    pthread_mutex_unlock(&queue->lock);
    return self;
}

static VALUE
queue_pop(int argc, VALUE *argv, VALUE self)
{
    queue_t *queue = get_queue(self);
    queue_timeout_t timeout = parse_timeout(extract_timeout(argc, argv));

    for (;;) {
        pthread_mutex_lock(&queue->lock);
        if (queue->closed) {
            pthread_mutex_unlock(&queue->lock);
            raise_queue_closed();
        }
        if (queue->size > 0) {
            VALUE value = queue->values[queue->head];
            queue->values[queue->head] = Qnil;
            queue->head = (queue->head + 1) % queue->storage_capacity;
            queue->size--;
            queue_update_readiness(queue);
            pthread_mutex_unlock(&queue->lock);
            return value;
        }
        if (!queue_wait(queue, &queue->can_pop, &queue->pop_waiters, &timeout)) {
            return rb_block_given_p() ? rb_yield_values(0) : Qnil;
        }
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
    rb_scan_args(argc, argv, "1:", &value, &keywords);
    if (!NIL_P(keywords)) {
        rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);
        if (keyword_values[0] != Qundef) timeout_value = keyword_values[0];
    }

    queue_t *queue = get_queue(self);
    containers_check_shareable(value);
    queue_timeout_t timeout = parse_timeout(timeout_value);
    for (;;) {
        pthread_mutex_lock(&queue->lock);
        if (queue->closed) {
            pthread_mutex_unlock(&queue->lock);
            raise_queue_closed();
        }
        if (!queue->bounded || queue->size < queue->limit) {
            if (queue->size == queue->storage_capacity && !queue_grow(queue)) {
                pthread_mutex_unlock(&queue->lock);
                rb_memerror();
            }
            queue->values[queue->tail] = value;
            queue->tail = (queue->tail + 1) % queue->storage_capacity;
            queue->size++;
            queue_update_readiness(queue);
            pthread_mutex_unlock(&queue->lock);
            return Qtrue;
        }
        if (!queue_wait(queue, &queue->can_push, &queue->push_waiters, &timeout)) return Qfalse;
    }
}

static VALUE
queue_wait_pop(int argc, VALUE *argv, VALUE self)
{
    queue_t *queue = get_queue(self);
    queue_timeout_t timeout = parse_timeout(extract_timeout(argc, argv));
    for (;;) {
        pthread_mutex_lock(&queue->lock);
        if (queue->closed) {
            pthread_mutex_unlock(&queue->lock);
            raise_queue_closed();
        }
        bool ready = queue->size > 0;
        if (ready) {
            pthread_mutex_unlock(&queue->lock);
            return Qtrue;
        }
        if (!queue_wait(queue, &queue->can_pop, &queue->pop_waiters, &timeout)) return Qfalse;
    }
}

static VALUE
queue_wait_push(int argc, VALUE *argv, VALUE self)
{
    queue_t *queue = get_queue(self);
    queue_timeout_t timeout = parse_timeout(extract_timeout(argc, argv));
    for (;;) {
        pthread_mutex_lock(&queue->lock);
        if (queue->closed) {
            pthread_mutex_unlock(&queue->lock);
            raise_queue_closed();
        }
        bool ready = !queue->bounded || queue->size < queue->limit;
        if (ready) {
            pthread_mutex_unlock(&queue->lock);
            return Qtrue;
        }
        if (!queue_wait(queue, &queue->can_push, &queue->push_waiters, &timeout)) return Qfalse;
    }
}


void
containers_init_queue(VALUE namespace)
{
    eClosedQueueError = rb_const_get(rb_cObject, rb_intern("ClosedQueueError"));
    cQueue = rb_define_class_under(namespace, "Queue", rb_cObject);
    rb_define_alloc_func(cQueue, queue_allocate);
    rb_define_method(cQueue, "initialize", queue_initialize, -1);
    rb_define_method(cQueue, "capacity", queue_capacity, 0);
    rb_define_method(cQueue, "size", queue_size, 0);
    rb_define_method(cQueue, "clear", queue_clear, 0);
    rb_define_method(cQueue, "pop", queue_pop, -1);
    rb_define_method(cQueue, "push", queue_push, -1);
    rb_define_method(cQueue, "wait_pop", queue_wait_pop, -1);
    rb_define_method(cQueue, "wait_push", queue_wait_push, -1);
    rb_define_method(cQueue, "close", queue_close, 0);
    rb_define_method(cQueue, "closed?", queue_closed_p, 0);
    rb_define_private_method(cQueue, "__release_wait_descriptors__", queue_release_wait_descriptors, 0);
}
