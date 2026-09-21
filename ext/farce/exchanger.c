#include "containers.h"
#include "ruby/io.h"

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <time.h>
#include <unistd.h>

static VALUE cExchanger;

typedef struct {
    int read_fd;
    int write_fd;
} exchanger_signal_t;

typedef struct exchanger_waiter {
    VALUE offered;
    VALUE received;
    exchanger_signal_t signal;
    bool matched;
} exchanger_waiter_t;

typedef struct {
    pthread_mutex_t lock;
    exchanger_waiter_t *waiting;
    bool initialized;
} exchanger_t;

typedef struct {
    bool finite;
    double deadline;
} exchanger_timeout_t;

typedef struct {
    exchanger_t *exchanger;
    exchanger_waiter_t *waiter;
    exchanger_timeout_t *timeout;
} exchanger_wait_context_t;

static void
exchanger_set_fd_flags(int fd)
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
exchanger_signal_initialize(exchanger_signal_t *signal)
{
    int descriptors[2];
    if (pipe(descriptors) != 0) return false;
    signal->read_fd = descriptors[0];
    signal->write_fd = descriptors[1];
    exchanger_set_fd_flags(signal->read_fd);
    exchanger_set_fd_flags(signal->write_fd);
    return true;
}

static void
exchanger_signal_close(exchanger_signal_t *signal)
{
    if (signal->read_fd >= 0) close(signal->read_fd);
    if (signal->write_fd >= 0) close(signal->write_fd);
    signal->read_fd = -1;
    signal->write_fd = -1;
}

static void
exchanger_signal_set(exchanger_signal_t *signal)
{
    unsigned char byte = 1;
    ssize_t result;

    do {
        result = write(signal->write_fd, &byte, 1);
    } while (result < 0 && errno == EINTR);
}

static double
exchanger_monotonic_now(void)
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

static exchanger_timeout_t
exchanger_parse_timeout(VALUE timeout)
{
    exchanger_timeout_t parsed = {.finite = false, .deadline = 0};
    if (NIL_P(timeout)) return parsed;

    double seconds = NUM2DBL(timeout);
    if (!isfinite(seconds) || seconds < 0) {
        rb_raise(rb_eArgError, "timeout must be a finite, non-negative number or nil");
    }
    parsed.finite = true;
    parsed.deadline = exchanger_monotonic_now() + seconds;
    return parsed;
}

static bool
exchanger_wait_for_descriptor(int fd, exchanger_timeout_t *timeout)
{
    VALUE wait_timeout = Qnil;
    if (timeout->finite) {
        double remaining = timeout->deadline - exchanger_monotonic_now();
        if (remaining <= 0) return false;
        wait_timeout = DBL2NUM(remaining);
    }

    return containers_wait_for_readable(fd, wait_timeout);
}

static void
exchanger_free(void *pointer)
{
    exchanger_t *exchanger = pointer;
    pthread_mutex_destroy(&exchanger->lock);
    ruby_xfree(exchanger);
}

static size_t
exchanger_memsize(const void *pointer)
{
    return pointer ? sizeof(exchanger_t) : 0;
}

static const rb_data_type_t exchanger_type = {
    .wrap_struct_name = "Ractor::Containers::Exchanger",
    .function = {
        .dmark = NULL,
        .dfree = exchanger_free,
        .dsize = exchanger_memsize,
        .dcompact = NULL,
    },
    .flags = RUBY_TYPED_FROZEN_SHAREABLE,
};

static VALUE
exchanger_allocate(VALUE klass)
{
    exchanger_t *exchanger;
    VALUE object = TypedData_Make_Struct(klass, exchanger_t, &exchanger_type, exchanger);
    pthread_mutex_init(&exchanger->lock, NULL);
    exchanger->waiting = NULL;
    exchanger->initialized = false;
    return object;
}

static exchanger_t *
get_exchanger(VALUE self)
{
    exchanger_t *exchanger;
    TypedData_Get_Struct(self, exchanger_t, &exchanger_type, exchanger);
    if (!exchanger->initialized) rb_raise(rb_eRuntimeError, "uninitialized Exchanger");
    return exchanger;
}

static VALUE
exchanger_frozen_p(VALUE self)
{
    (void)self;
    return Qfalse;
}

static VALUE
exchanger_freeze(VALUE self)
{
    containers_raise_unfreezable(self);
    return Qnil;
}

static VALUE
exchanger_initialize(VALUE self)
{
    exchanger_t *exchanger;
    TypedData_Get_Struct(self, exchanger_t, &exchanger_type, exchanger);
    if (exchanger->initialized) rb_raise(rb_eRuntimeError, "Exchanger is already initialized");
    exchanger->initialized = true;
    containers_publish_native_reference_free(self);
    return self;
}

static VALUE
exchanger_wait_body(VALUE opaque)
{
    exchanger_wait_context_t *context = (exchanger_wait_context_t *)opaque;
    return exchanger_wait_for_descriptor(context->waiter->signal.read_fd, context->timeout)
        ? Qtrue
        : Qfalse;
}

static VALUE
exchanger_wait_cleanup(VALUE opaque)
{
    exchanger_wait_context_t *context = (exchanger_wait_context_t *)opaque;
    pthread_mutex_lock(&context->exchanger->lock);
    if (context->exchanger->waiting == context->waiter) {
        context->exchanger->waiting = NULL;
    }
    pthread_mutex_unlock(&context->exchanger->lock);
    exchanger_signal_close(&context->waiter->signal);
    return Qnil;
}

static VALUE
exchanger_exchange(int argc, VALUE *argv, VALUE self)
{
    VALUE offered;
    VALUE keywords = Qnil;
    VALUE timeout_value = Qnil;
    ID keyword_ids[] = {rb_intern("timeout")};
    VALUE keyword_values[1];

    rb_scan_args(argc, argv, "1:", &offered, &keywords);
    if (!NIL_P(keywords)) {
        rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);
        if (keyword_values[0] != Qundef) timeout_value = keyword_values[0];
    }

    containers_check_shareable(offered);
    exchanger_timeout_t timeout = exchanger_parse_timeout(timeout_value);
    exchanger_t *exchanger = get_exchanger(self);

    pthread_mutex_lock(&exchanger->lock);
    if (exchanger->waiting != NULL) {
        exchanger_waiter_t *partner = exchanger->waiting;
        exchanger->waiting = NULL;
        VALUE received = partner->offered;
        partner->received = offered;
        partner->matched = true;
        exchanger_signal_set(&partner->signal);
        pthread_mutex_unlock(&exchanger->lock);
        RB_GC_GUARD(offered);
        return received;
    }

    if (timeout.finite && timeout.deadline <= exchanger_monotonic_now()) {
        pthread_mutex_unlock(&exchanger->lock);
        return rb_block_given_p() ? rb_yield_values(0) : Qnil;
    }

    exchanger_waiter_t waiter = {
        .offered = offered,
        .received = Qnil,
        .signal = {.read_fd = -1, .write_fd = -1},
        .matched = false,
    };
    if (!exchanger_signal_initialize(&waiter.signal)) {
        int error = errno;
        pthread_mutex_unlock(&exchanger->lock);
        errno = error;
        rb_sys_fail("pipe");
    }
    exchanger->waiting = &waiter;
    pthread_mutex_unlock(&exchanger->lock);

    exchanger_wait_context_t context = {
        .exchanger = exchanger,
        .waiter = &waiter,
        .timeout = &timeout,
    };
    (void)rb_ensure(
        exchanger_wait_body,
        (VALUE)&context,
        exchanger_wait_cleanup,
        (VALUE)&context
    );

    RB_GC_GUARD(offered);
    RB_GC_GUARD(waiter.received);
    if (waiter.matched) return waiter.received;
    return rb_block_given_p() ? rb_yield_values(0) : Qnil;
}

void
containers_init_exchanger(VALUE namespace)
{
    cExchanger = rb_define_class_under(namespace, "Exchanger", rb_cObject);
    rb_define_alloc_func(cExchanger, exchanger_allocate);
    rb_define_method(cExchanger, "initialize", exchanger_initialize, 0);
    rb_define_method(cExchanger, "exchange", exchanger_exchange, -1);
    rb_define_method(cExchanger, "freeze", exchanger_freeze, 0);
    rb_define_method(cExchanger, "frozen?", exchanger_frozen_p, 0);
}
