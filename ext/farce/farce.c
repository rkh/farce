#include "containers.h"
#include "ruby/fiber/scheduler.h"
#include "ruby/io.h"

#include <errno.h>
#include <math.h>
#include <unistd.h>

#ifdef _WIN32
#include <io.h>
#include <windows.h>
#endif

static VALUE eIsolationError;

void farce_init_fiber_scheduler(VALUE namespace);

RBIMPL_ATTR_NORETURN()
static void
raise_unshareable(VALUE value)
{
    rb_raise(eIsolationError, "value is not shareable: %" PRIsVALUE, rb_inspect(value));
}

void
containers_check_shareable(VALUE value)
{
    if (!rb_ractor_shareable_p(value)) raise_unshareable(value);
}

bool
containers_strict_bool(VALUE value, const char *name)
{
    if (value == Qtrue) return true;
    if (value == Qfalse) return false;
    rb_raise(rb_eArgError, "%s must be true or false", name);
}

void
containers_finish_initialization(VALUE self)
{
    rb_obj_freeze(self);
    rb_ractor_make_shareable(self);
}

typedef struct {
    int fd;
    ssize_t result;
    int error;
#ifdef _WIN32
    bool consume;
#endif
} containers_read_context_t;

static void *
containers_poll_without_gvl(void *opaque)
{
    containers_read_context_t *context = opaque;
#ifdef _WIN32
    intptr_t descriptor = _get_osfhandle(context->fd);
    if (descriptor == -1) {
        context->error = EBADF;
        return NULL;
    }

    HANDLE handle = (HANDLE)descriptor;
    DWORD available = 0;
    if (!PeekNamedPipe(handle, NULL, 0, NULL, &available, NULL)) {
        context->error = EIO;
        return NULL;
    }
    if (available == 0) return NULL;
    if (!context->consume) {
        context->result = 1;
        return NULL;
    }
    do {
        context->result = read(context->fd, &(unsigned char){0}, 1);
    } while (context->result < 0 && errno == EINTR);
    context->error = errno;
#else
    do {
        context->result = read(context->fd, &(unsigned char){0}, 1);
    } while (context->result < 0 && errno == EINTR);
    context->error = errno;
#endif
    return NULL;
}

#ifdef _WIN32
static void *
containers_sleep_without_gvl(void *opaque)
{
    (void)opaque;
    /* Ruby redirects Sleep to rb_w32_Sleep, which requires the GVL. */
    SleepEx(1, FALSE);
    return NULL;
}

static void *
containers_read_without_gvl(void *opaque)
{
    containers_read_context_t *context = opaque;
    do {
        context->result = read(context->fd, &(unsigned char){0}, 1);
    } while (context->result < 0 && errno == EINTR);
    context->error = errno;
    return NULL;
}
#endif

static VALUE
containers_io_wait(VALUE opaque)
{
    VALUE *arguments = (VALUE *)opaque;
    return rb_io_wait(arguments[0], INT2NUM(RUBY_IO_READABLE), arguments[1]);
}

static VALUE
containers_io_close(VALUE opaque)
{
    VALUE *arguments = (VALUE *)opaque;
    return rb_io_close(arguments[0]);
}

static bool
containers_wait_for_readable_mode(int fd, VALUE timeout, bool consume)
{
#ifdef _WIN32
    /* CRuby's anonymous-pipe polling can stop making progress on Windows.
     * Consume indefinite one-shot notifications with a blocking read; timed
     * waits use short no-GVL probes so Ruby regains control between slices.
     * Scheduler-backed waits retain rb_io_wait integration. */
    if (NIL_P(rb_fiber_scheduler_current())) {
        if (NIL_P(timeout) && consume) {
            containers_read_context_t context = {
                .fd = fd,
                .result = -1,
                .error = 0,
                .consume = true,
            };
            rb_thread_call_without_gvl(
                containers_read_without_gvl,
                &context,
                RUBY_UBF_IO,
                NULL
            );
            if (context.result < 0) {
                errno = context.error;
                rb_sys_fail("read");
            }
            return true;
        }
        double seconds = NIL_P(timeout) ? 0 : NUM2DBL(timeout);
        bool finite = !NIL_P(timeout);
        ULONGLONG deadline = GetTickCount64() + (ULONGLONG)ceil(seconds * 1000);
        containers_read_context_t context = {
            .fd = fd,
            .result = -1,
            .error = 0,
            .consume = consume,
        };
        for (;;) {
            context.result = 0;
            context.error = 0;
            rb_thread_call_without_gvl(
                containers_poll_without_gvl,
                &context,
                NULL,
                NULL
            );
            if (context.error) {
                errno = context.error;
                rb_sys_fail("read");
            }
            if (context.result > 0) return true;
            if (finite && GetTickCount64() >= deadline) return false;
            rb_thread_call_without_gvl(
                containers_sleep_without_gvl,
                NULL,
                NULL,
                NULL
            );
        }
    }
#endif

    VALUE arguments[] = {
        rb_io_open_descriptor(
            rb_cIO,
            fd,
            FMODE_READABLE | FMODE_EXTERNAL,
            Qnil,
            Qnil,
            NULL
        ),
        timeout,
    };
    VALUE result = rb_ensure(
        containers_io_wait,
        (VALUE)arguments,
        containers_io_close,
        (VALUE)arguments
    );
    RB_GC_GUARD(arguments[0]);
    return RTEST(result);
}

bool
containers_wait_for_readable(int fd, VALUE timeout)
{
    return containers_wait_for_readable_mode(fd, timeout, true);
}

bool
containers_wait_for_readable_level(int fd, VALUE timeout)
{
    return containers_wait_for_readable_mode(fd, timeout, false);
}

void
containers_raise_key_error(VALUE receiver, VALUE key)
{
    VALUE message = rb_sprintf("key not found: %" PRIsVALUE, rb_inspect(key));
    VALUE keywords = rb_hash_new();
    rb_hash_aset(keywords, ID2SYM(rb_intern("receiver")), receiver);
    rb_hash_aset(keywords, ID2SYM(rb_intern("key")), key);
    VALUE arguments[] = {message, keywords};
    VALUE exception = rb_class_new_instance_kw(2, arguments, rb_eKeyError, RB_PASS_KEYWORDS);
    rb_exc_raise(exception);
}

static VALUE
farce_load_native_fiber_scheduler(VALUE namespace)
{
    farce_init_fiber_scheduler(namespace);
    return Qnil;
}

RUBY_FUNC_EXPORTED void
Init_farce(void)
{
    rb_ext_ractor_safe(true);
    VALUE mFarce    = rb_const_get(rb_cObject, rb_intern("Farce"));
    VALUE mInternal = rb_const_get(mFarce, rb_intern("Internal"));
    VALUE singleton = rb_singleton_class(mInternal);
    eIsolationError = rb_const_get(rb_cRactor, rb_intern("IsolationError"));
    rb_define_private_method(
        singleton,
        "load_native_fiber_scheduler",
        farce_load_native_fiber_scheduler,
        0
    );
    containers_init_atom(mInternal);
    containers_init_counter(mInternal);
    containers_init_exchanger(mInternal);
    containers_init_flag(mInternal);
    containers_init_lock(mInternal);
    containers_init_map(mInternal);
    containers_init_priority_queue(mInternal);
    containers_init_darwin(mInternal);
    containers_init_queue(mInternal);
    containers_init_signal(mInternal);
    containers_init_unshared_signal(mInternal);
    containers_init_unshareable(mInternal);
    containers_init_vector(mInternal);
    containers_init_weak_maps(mInternal);
    containers_init_tree_maps(mInternal);
}
