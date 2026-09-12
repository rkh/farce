#include "containers.h"
#include "ruby/io.h"

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>

static VALUE cSignal;

typedef struct containers_signal_waiter containers_signal_waiter_t;

struct containers_signal_waiter {
    int read_fd;
    int write_fd;
    bool notified;
    containers_signal_waiter_t *next;
};

typedef struct {
    pthread_mutex_t lock;
    containers_signal_waiter_t *waiters;
    uint64_t generation;
    bool initialized;
} containers_signal_t;

typedef struct {
    bool finite;
    double deadline;
} containers_signal_timeout_t;

typedef struct {
    containers_signal_t *signal;
    containers_signal_waiter_t waiter;
    containers_signal_timeout_t *timeout;
} containers_signal_wait_context_t;

static double
containers_signal_monotonic_now(void)
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

static containers_signal_timeout_t
containers_signal_parse_timeout(VALUE value)
{
    containers_signal_timeout_t timeout = {.finite = false, .deadline = 0};
    if (NIL_P(value)) return timeout;

    double seconds = NUM2DBL(value);
    if (!isfinite(seconds) || seconds < 0) {
        rb_raise(rb_eArgError, "timeout must be a finite, non-negative number or nil");
    }
    timeout.finite = true;
    timeout.deadline = containers_signal_monotonic_now() + seconds;
    return timeout;
}

static void
containers_signal_set_fd_flags(int fd)
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

/* Called with signal->lock held. Each waiter has a separate descriptor, so a
 * single broadcast makes every scheduled Fiber or native thread runnable. */
static void
containers_signal_notify_waiters_locked(containers_signal_t *signal)
{
    unsigned char byte = 1;
    for (containers_signal_waiter_t *waiter = signal->waiters; waiter; waiter = waiter->next) {
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
containers_signal_free(void *pointer)
{
    containers_signal_t *signal = pointer;
    pthread_mutex_destroy(&signal->lock);
    ruby_xfree(signal);
}

static size_t
containers_signal_memsize(const void *pointer)
{
    return pointer ? sizeof(containers_signal_t) : 0;
}

static const rb_data_type_t containers_signal_type = {
    .wrap_struct_name = "Ractor::Containers::Signal",
    .function = {
        .dmark = NULL,
        .dfree = containers_signal_free,
        .dsize = containers_signal_memsize,
        .dcompact = NULL,
    },
    .flags = RUBY_TYPED_FROZEN_SHAREABLE,
};

static VALUE
containers_signal_allocate(VALUE klass)
{
    containers_signal_t *signal;
    VALUE object = TypedData_Make_Struct(
        klass,
        containers_signal_t,
        &containers_signal_type,
        signal
    );
    pthread_mutex_init(&signal->lock, NULL);
    signal->waiters = NULL;
    signal->generation = 0;
    signal->initialized = false;
    return object;
}

static containers_signal_t *
containers_signal_get(VALUE self)
{
    containers_signal_t *signal;
    TypedData_Get_Struct(self, containers_signal_t, &containers_signal_type, signal);
    if (!signal->initialized) rb_raise(rb_eRuntimeError, "uninitialized Signal");
    return signal;
}

static VALUE
containers_signal_initialize(VALUE self)
{
    containers_signal_t *signal;
    TypedData_Get_Struct(self, containers_signal_t, &containers_signal_type, signal);
    if (signal->initialized) rb_raise(rb_eRuntimeError, "Signal is already initialized");
    signal->initialized = true;
    containers_finish_initialization(self);
    return self;
}

static bool
containers_signal_wait_for_descriptor(int fd, containers_signal_timeout_t *timeout)
{
    VALUE wait_timeout = Qnil;
    if (timeout->finite) {
        double remaining = timeout->deadline - containers_signal_monotonic_now();
        if (remaining <= 0) return false;
        wait_timeout = DBL2NUM(remaining);
    }

    return containers_wait_for_readable(fd, wait_timeout);
}

static VALUE
containers_signal_wait_body(VALUE opaque)
{
    containers_signal_wait_context_t *context = (containers_signal_wait_context_t *)opaque;
    return containers_signal_wait_for_descriptor(context->waiter.read_fd, context->timeout)
        ? Qtrue
        : Qfalse;
}

static VALUE
containers_signal_wait_cleanup(VALUE opaque)
{
    containers_signal_wait_context_t *context = (containers_signal_wait_context_t *)opaque;
    containers_signal_waiter_t **link;

    pthread_mutex_lock(&context->signal->lock);
    for (link = &context->signal->waiters; *link; link = &(*link)->next) {
        if (*link == &context->waiter) {
            *link = context->waiter.next;
            break;
        }
    }
    pthread_mutex_unlock(&context->signal->lock);
    close(context->waiter.read_fd);
    close(context->waiter.write_fd);
    return Qnil;
}

/* Called with signal->lock held and always returns with it released. */
static bool
containers_signal_wait_once(
    containers_signal_t *signal,
    containers_signal_timeout_t *timeout
)
{
    int descriptors[2];
    if (pipe(descriptors) != 0) {
        pthread_mutex_unlock(&signal->lock);
        rb_sys_fail("pipe");
    }
    containers_signal_set_fd_flags(descriptors[0]);
    containers_signal_set_fd_flags(descriptors[1]);

    containers_signal_wait_context_t context = {
        .signal = signal,
        .waiter = {
            .read_fd = descriptors[0],
            .write_fd = descriptors[1],
            .notified = false,
            .next = signal->waiters,
        },
        .timeout = timeout,
    };
    signal->waiters = &context.waiter;
    pthread_mutex_unlock(&signal->lock);
    return RTEST(rb_ensure(
        containers_signal_wait_body,
        (VALUE)&context,
        containers_signal_wait_cleanup,
        (VALUE)&context
    ));
}

static VALUE
containers_signal_timeout_result(void)
{
    return rb_block_given_p() ? rb_yield_values(0) : Qnil;
}

static VALUE
containers_signal_generation(VALUE self)
{
    containers_signal_t *signal = containers_signal_get(self);
    uint64_t generation;
    pthread_mutex_lock(&signal->lock);
    generation = signal->generation;
    pthread_mutex_unlock(&signal->lock);
    return ULL2NUM(generation);
}

static VALUE
containers_signal_num_waiting(VALUE self)
{
    containers_signal_t *signal = containers_signal_get(self);
    size_t count = 0;

    /* Count on demand so wait and broadcast have no additional bookkeeping. */
    pthread_mutex_lock(&signal->lock);
    for (containers_signal_waiter_t *waiter = signal->waiters; waiter; waiter = waiter->next) {
        count++;
    }
    pthread_mutex_unlock(&signal->lock);
    return SIZET2NUM(count);
}

static VALUE
containers_signal_broadcast(VALUE self)
{
    containers_signal_t *signal = containers_signal_get(self);
    uint64_t generation;
    pthread_mutex_lock(&signal->lock);
    signal->generation++;
    generation = signal->generation;
    containers_signal_notify_waiters_locked(signal);
    pthread_mutex_unlock(&signal->lock);
    return ULL2NUM(generation);
}

static VALUE
containers_signal_wait(int argc, VALUE *argv, VALUE self)
{
    VALUE observed_value = Qnil;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    rb_scan_args(argc, argv, "01:", &observed_value, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    bool snapshot_at_entry = NIL_P(observed_value);
    uint64_t observed = snapshot_at_entry ? 0 : NUM2ULL(observed_value);
    containers_signal_timeout_t timeout = containers_signal_parse_timeout(
        keyword_values[0] == Qundef ? Qnil : keyword_values[0]
    );
    containers_signal_t *signal = containers_signal_get(self);

    pthread_mutex_lock(&signal->lock);
    if (snapshot_at_entry) observed = signal->generation;
    for (;;) {
        if (signal->generation != observed) {
            uint64_t generation = signal->generation;
            pthread_mutex_unlock(&signal->lock);
            return ULL2NUM(generation);
        }
        bool awakened = containers_signal_wait_once(signal, &timeout);
        pthread_mutex_lock(&signal->lock);
        if (!awakened && signal->generation == observed) {
            pthread_mutex_unlock(&signal->lock);
            return containers_signal_timeout_result();
        }
    }
}

void
containers_init_signal(VALUE namespace)
{
    cSignal = rb_define_class_under(namespace, "Signal", rb_cObject);
    rb_define_alloc_func(cSignal, containers_signal_allocate);
    rb_define_method(cSignal, "initialize", containers_signal_initialize, 0);
    rb_define_method(cSignal, "generation", containers_signal_generation, 0);
    rb_define_method(cSignal, "num_waiting", containers_signal_num_waiting, 0);
    rb_define_method(cSignal, "broadcast", containers_signal_broadcast, 0);
    rb_define_method(cSignal, "wait", containers_signal_wait, -1);
}
