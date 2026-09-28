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
#ifdef _WIN32
#include <windows.h>
#endif

static VALUE cQueue;
static ID id_farce;
static ID id_closed_error;
static ID id_sealed_error;
static ID id_timeout;
#ifdef _WIN32
static rb_ractor_local_key_t queue_main_ractor_key;
#endif

#define QUEUE_INITIAL_CAPACITY 16

typedef struct {
    int read_fd;
    int write_fd;
    bool set;
#ifdef _WIN32
    HANDLE event;
#endif
} readiness_signal_t;

typedef struct {
    pthread_mutex_t lock;
    VALUE *values;
    double *enqueued_at;
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
    bool sealed;
    bool closed;
    bool track_age;
    uint64_t generation;
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
#ifdef _WIN32
    signal->event = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!signal->event) {
        close(descriptors[0]);
        close(descriptors[1]);
        errno = EIO;
        return false;
    }
#endif
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
#ifdef _WIN32
    if (signal->event) CloseHandle(signal->event);
    signal->event = NULL;
#endif
}

static void
readiness_set(readiness_signal_t *signal, bool desired)
{
    unsigned char byte = 1;
    ssize_t result;
    if (signal->read_fd < 0) return;
    if (desired == signal->set) {
#ifdef _WIN32
        /* The unblock callback can set the event without a readiness byte.
         * Clear that interrupt wakeup when the queue is still not ready. */
        if (!desired) ResetEvent(signal->event);
#endif
        return;
    }
    if (desired) {
        do {
            result = write(signal->write_fd, &byte, 1);
        } while (result < 0 && errno == EINTR);
        if (result == 1 || (result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))) {
            signal->set = true;
#ifdef _WIN32
            SetEvent(signal->event);
#endif
        }
    }
    else {
        do {
            result = read(signal->read_fd, &byte, 1);
        } while (result < 0 && errno == EINTR);
        if (result == 1 || (result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))) {
            signal->set = false;
#ifdef _WIN32
            ResetEvent(signal->event);
#endif
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
        if (queue->sealed || !queue->bounded || queue->size < queue->limit) {
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
            (queue->sealed || !queue->bounded || queue->size < queue->limit)
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
    free(queue->enqueued_at);
    readiness_close(&queue->can_pop);
    readiness_close(&queue->can_push);
    ruby_xfree(queue);
}

static size_t
queue_memsize(const void *pointer)
{
    const queue_t *queue = pointer;
    return queue ? sizeof(queue_t) + queue->storage_capacity *
        (sizeof(VALUE) + (queue->track_age ? sizeof(double) : 0)) : 0;
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
    queue->enqueued_at = NULL;
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
    queue->sealed = false;
    queue->closed = false;
    queue->track_age = false;
    queue->generation = 0;
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

static void
queue_validate_references(VALUE self)
{
    queue_t *queue = get_queue(self);

    if (queue->size != 0 || queue->unshared_pop_waiters.count != 0 ||
        queue->unshared_push_waiters.count != 0) {
        rb_raise(rb_eRuntimeError, "queue publication requires empty storage");
    }
}

static VALUE
queue_freeze(VALUE self)
{
    queue_t *queue;
    TypedData_Get_Struct(self, queue_t, &queue_type, queue);
    if (queue->shared) containers_raise_unfreezable(self);
    return rb_obj_freeze(self);
}

static VALUE
queue_frozen_p(VALUE self)
{
    queue_t *queue;
    TypedData_Get_Struct(self, queue_t, &queue_type, queue);
    return queue->shared ? Qfalse : rb_obj_frozen_p(self);
}

static VALUE
queue_initialize(int argc, VALUE *argv, VALUE self)
{
    VALUE keywords = Qnil;
    VALUE capacity_value = Qundef;
    ID keyword_ids[] = {rb_intern("capacity"), rb_intern("track_age"), rb_intern("fiber_wait")};
    VALUE keyword_values[3] = {Qundef, Qundef, Qundef};
    queue_t *queue;
    TypedData_Get_Struct(self, queue_t, &queue_type, queue);
    rb_scan_args(argc, argv, "0:", &keywords);
    if (!NIL_P(keywords)) {
        rb_get_kwargs(keywords, keyword_ids, 0, queue->shared ? 2 : 3, keyword_values);
        capacity_value = keyword_values[0];
    }
    if (queue->initialized) rb_raise(rb_eRuntimeError, "Queue is already initialized");
    bool fiber_io = containers_unshared_fiber_io(keyword_values[2]);

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
    VALUE track_age = keyword_values[1];
    queue->track_age = track_age != Qundef && RTEST(track_age);
    if (queue->track_age) {
        queue->enqueued_at = calloc(queue->storage_capacity, sizeof(double));
        if (!queue->enqueued_at) rb_memerror();
    }
    queue->unshared_fiber_io = fiber_io;
    queue->initialized = true;
    if (queue->shared) containers_publish_native_with_references(self, queue_validate_references);
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

static bool
queue_wait_for_descriptor(int fd, queue_timeout_t *timeout)
{
    VALUE wait_timeout = Qnil;
    if (timeout->finite) {
        double remaining = timeout->deadline - monotonic_now();
        if (remaining <= 0) return false;
        wait_timeout = DBL2NUM(remaining);
    }
    return containers_wait_for_readable(fd, wait_timeout);
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

#ifdef _WIN32
typedef struct {
    HANDLE event;
    DWORD timeout;
    DWORD result;
} queue_event_wait_t;

static void *
queue_event_wait_without_gvl(void *opaque)
{
    queue_event_wait_t *wait = (queue_event_wait_t *)opaque;
    wait->result = WaitForSingleObject(wait->event, wait->timeout);
    return NULL;
}

static void
queue_event_wait_interrupt(void *opaque)
{
    queue_event_wait_t *wait = (queue_event_wait_t *)opaque;
    SetEvent(wait->event);
}

static VALUE
queue_event_wait_body(VALUE opaque)
{
    queue_wait_context_t *context = (queue_wait_context_t *)opaque;
    /* Bound event waits so we can join VM barriers even when Ruby's Windows
     * interrupt does not invoke the unblock callback. */
    for (;;) {
        DWORD timeout = 10;
        if (context->timeout->finite) {
            double remaining = context->timeout->deadline - monotonic_now();
            if (remaining <= 0) return Qfalse;
            if (remaining < 0.01) timeout = (DWORD)ceil(remaining * 1000);
        }
        queue_event_wait_t wait = {
            .event = context->signal->event,
            .timeout = timeout,
            .result = WAIT_FAILED,
        };
        rb_thread_call_without_gvl(
            queue_event_wait_without_gvl,
            &wait,
            queue_event_wait_interrupt,
            &wait
        );
        if (wait.result == WAIT_TIMEOUT) {
            containers_wait_safepoint();
            continue;
        }
        if (wait.result == WAIT_OBJECT_0) return Qtrue;
        errno = EIO;
        rb_sys_fail("WaitForSingleObject");
    }
}
#endif

static VALUE
queue_wait_cleanup(VALUE opaque)
{
    queue_wait_context_t *context = (queue_wait_context_t *)opaque;
    if (context->wait_fd >= 0) close(context->wait_fd);
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
#ifdef _WIN32
    VALUE main_ractor_marker;
    bool in_main_ractor = rb_ractor_local_storage_value_lookup(
        queue_main_ractor_key,
        &main_ractor_marker
    );
    if (in_main_ractor && NIL_P(rb_fiber_scheduler_current())) {
        queue_wait_context_t context = {
            .queue = queue,
            .signal = signal,
            .waiter_count = waiter_count,
            .timeout = timeout,
            .wait_fd = -1,
        };
        (*waiter_count)++;
        queue_update_readiness(queue);
        queue_unlock(queue);
        return RTEST(rb_ensure(queue_event_wait_body, (VALUE)&context, queue_wait_cleanup, (VALUE)&context));
    }
#endif
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
    VALUE farce = rb_const_get(rb_cObject, id_farce);
    rb_raise(rb_const_get(farce, id_closed_error), "queue is closed");
}

RBIMPL_ATTR_NORETURN()
static void
raise_queue_sealed(void)
{
    VALUE farce = rb_const_get(rb_cObject, id_farce);
    rb_raise(rb_const_get(farce, id_sealed_error), "queue is sealed");
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
    double *enqueued_at = NULL;
    if (queue->track_age) {
        enqueued_at = calloc(grown, sizeof(double));
        if (!enqueued_at) {
            free(values);
            return false;
        }
    }

    for (size_t index = 0; index < queue->size; index++) {
        size_t source = (queue->head + index) % current;
        values[index] = queue->values[source];
        if (queue->track_age) enqueued_at[index] = queue->enqueued_at[source];
    }
    free(queue->values);
    free(queue->enqueued_at);
    queue->values = values;
    queue->enqueued_at = enqueued_at;
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
        if (queue->track_age) queue->enqueued_at[index] = 0;
        index++;
        if (index == queue->storage_capacity) index = 0;
    }
    if (queue->size > 0 && queue->track_age) queue->generation++;
    queue->size = 0;
    queue->head = 0;
    queue->tail = 0;
    if (queue->sealed) queue->closed = true;
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
queue_sealed_p(VALUE self)
{
    queue_t *queue = get_queue(self);
    bool sealed;
    queue_lock(queue);
    sealed = queue->sealed;
    queue_unlock(queue);
    return sealed ? Qtrue : Qfalse;
}

static VALUE
queue_age_tracking_p(VALUE self)
{
    return get_queue(self)->track_age ? Qtrue : Qfalse;
}

static VALUE
queue_generation(VALUE self)
{
    queue_t *queue = get_queue(self);
    uint64_t generation;
    if (!queue->track_age) return Qnil;
    queue_lock(queue);
    generation = queue->generation;
    queue_unlock(queue);
    return ULL2NUM(generation);
}

static VALUE
queue_oldest_enqueued_at(VALUE self)
{
    queue_t *queue = get_queue(self);
    double timestamp;
    if (!queue->track_age) return Qnil;
    queue_lock(queue);
    if (queue->size == 0) {
        queue_unlock(queue);
        return Qnil;
    }
    timestamp = queue->enqueued_at[queue->head];
    queue_unlock(queue);
    return DBL2NUM(timestamp);
}

static VALUE
queue_oldest_age(VALUE self)
{
    queue_t *queue = get_queue(self);
    double age;
    if (!queue->track_age) return Qnil;
    queue_lock(queue);
    if (queue->size == 0) {
        queue_unlock(queue);
        return Qnil;
    }
    age = monotonic_now() - queue->enqueued_at[queue->head];
    queue_unlock(queue);
    return DBL2NUM(age);
}

static VALUE
queue_seal(VALUE self)
{
    queue_t *queue = get_queue(self);
    queue_lock(queue);
    if (!queue->sealed) {
        queue->sealed = true;
        if (queue->size == 0) queue->closed = true;
        if (queue->track_age) queue->generation++;
        queue_update_readiness(queue);
    }
    queue_unlock(queue);
    return self;
}

static VALUE
queue_close(VALUE self)
{
    queue_t *queue = get_queue(self);
    queue_lock(queue);
    if (!queue->closed) {
        queue->sealed = true;
        queue->closed = true;
        if (queue->track_age) queue->generation++;
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
            if (queue->track_age) queue->enqueued_at[queue->head] = 0;
            if (++queue->head == queue->storage_capacity) queue->head = 0;
            queue->size--;
            if (queue->track_age) queue->generation++;
            if (queue->sealed && queue->size == 0) queue->closed = true;
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
        if (queue->sealed) {
            queue_unlock(queue);
            raise_queue_sealed();
        }
        if (!queue->bounded || queue->size < queue->limit) {
            if (queue->size == queue->storage_capacity && !queue_grow(queue)) {
                queue_unlock(queue);
                rb_memerror();
            }
            queue->values[queue->tail] = value;
            if (queue->track_age) queue->enqueued_at[queue->tail] = monotonic_now();
            if (++queue->tail == queue->storage_capacity) queue->tail = 0;
            queue->size++;
            if (queue->track_age) queue->generation++;
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
        if (queue->sealed) {
            queue_unlock(queue);
            raise_queue_sealed();
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
#ifdef _WIN32
    queue_main_ractor_key = rb_ractor_local_storage_value_newkey();
    rb_ractor_local_storage_value_set(queue_main_ractor_key, Qtrue);
#endif
    id_farce = rb_intern("Farce");
    id_closed_error = rb_intern("ClosedQueueError");
    id_sealed_error = rb_intern("SealedQueueError");
    id_timeout = rb_intern("timeout");
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
    rb_define_method(cQueue, "seal", queue_seal, 0);
    rb_define_method(cQueue, "closed?", queue_closed_p, 0);
    rb_define_method(cQueue, "sealed?", queue_sealed_p, 0);
    rb_define_method(cQueue, "age_tracking?", queue_age_tracking_p, 0);
    rb_define_method(cQueue, "generation", queue_generation, 0);
    rb_define_method(cQueue, "oldest_enqueued_at", queue_oldest_enqueued_at, 0);
    rb_define_method(cQueue, "oldest_age", queue_oldest_age, 0);
    rb_define_method(cQueue, "freeze", queue_freeze, 0);
    rb_define_method(cQueue, "frozen?", queue_frozen_p, 0);
    rb_define_private_method(cQueue, "__release_wait_descriptors__", queue_release_wait_descriptors, 0);
}
