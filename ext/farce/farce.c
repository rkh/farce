#include "containers.h"
#include "transaction.h"
#include "shareable.h"
#include "ruby/fiber/scheduler.h"
#include "ruby/io.h"

#include <errno.h>
#include <math.h>
#include <unistd.h>

#ifdef _WIN32
#include <io.h>
#include <windows.h>
/* Older MinGW headers omit this flag even when the runtime supports it. */
#ifndef CREATE_WAITABLE_TIMER_HIGH_RESOLUTION
#define CREATE_WAITABLE_TIMER_HIGH_RESOLUTION 0x00000002
#endif
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

static void
containers_check_native_publication_target(VALUE self)
{
    if (!RB_TYPE_P(self, T_DATA) || !RTYPEDDATA_P(self)) {
        rb_raise(rb_eTypeError, "native publication requires a typed-data object");
    }
    if (!(RTYPEDDATA_TYPE(self)->flags & RUBY_TYPED_FROZEN_SHAREABLE)) {
        rb_raise(rb_eTypeError, "native publication requires a shareable typed-data descriptor");
    }

    VALUE instance_variables = rb_obj_instance_variables(self);
    if (RARRAY_LEN(instance_variables) != 0) {
        rb_raise(
            rb_eTypeError,
            "%s cannot be published with Ruby instance variables",
            rb_obj_classname(self)
        );
    }
    RB_GC_GUARD(instance_variables);
}

VALUE
containers_publish_native_reference_free(VALUE self)
{
    containers_check_native_publication_target(self);
    return farce_ruby_mark_shareable(self);
}

VALUE
containers_publish_native_with_references(
    VALUE self,
    containers_native_reference_validator_t validate_references
)
{
    if (!validate_references) {
        rb_raise(rb_eArgError, "native publication requires a reference validator");
    }
    containers_check_native_publication_target(self);
    validate_references(self);
    return farce_ruby_mark_shareable(self);
}

VALUE
containers_raise_unfreezable(VALUE self)
{
    rb_raise(rb_eTypeError, "%s cannot be frozen", rb_obj_classname(self));
}

VALUE
containers_normalize_string_key(VALUE key)
{
    VALUE stored_key;

    if (!RB_TYPE_P(key, T_STRING)) return key;
    if (rb_obj_class(key) == rb_cString) return rb_str_to_interned_str(key);

    /* Preserve String subclasses and their instance state without dispatching
     * overridable duplication or freezing methods. */
    stored_key = rb_obj_alloc(rb_obj_class(key));
    rb_str_replace(stored_key, key);
    {
        VALUE instance_variables = rb_obj_instance_variables(key);
        long index;

        for (index = 0; index < RARRAY_LEN(instance_variables); index++) {
            ID id = SYM2ID(RARRAY_AREF(instance_variables, index));
            rb_ivar_set(stored_key, id, rb_ivar_get(key, id));
        }
        RB_GC_GUARD(instance_variables);
    }
    rb_obj_freeze(stored_key);
    return stored_key;
}

#ifdef _WIN32
typedef struct {
    int fd;
    bool readable;
    int error;
} containers_read_context_t;

static void *
containers_poll_without_gvl(void *opaque)
{
    containers_read_context_t *context = opaque;
    intptr_t descriptor = _get_osfhandle(context->fd);
    if (descriptor == -1) {
        context->error = EBADF;
        return NULL;
    }

    DWORD available = 0;
    if (!PeekNamedPipe((HANDLE)descriptor, NULL, 0, NULL, &available, NULL)) {
        context->error = EIO;
        return NULL;
    }
    /* Match rb_io_wait: observe readiness without consuming the notification.
     * The caller owns its notification's lifetime and cleanup. */
    context->readable = available > 0;
    return NULL;
}

RUBY_EXTERN void rb_objspace_reachable_objects_from(VALUE, void (*)(VALUE, void *), void *);

void
containers_wait_safepoint(void)
{
    /* A Windows VM-barrier interrupt can target a sleeping sibling thread.
     * Checking only this thread's interrupts then misses the pending barrier.
     * The exported reachability API acquires the VM lock and joins that barrier.
     * nil has no children, so this does not traverse, allocate, or collect. */
    rb_objspace_reachable_objects_from(Qnil, NULL, NULL);
}

static void *
containers_sleep_without_gvl(void *opaque)
{
    (void)opaque;
    /* SleepEx rounds short waits to the system timer tick. Keep pipe handoffs
     * responsive without changing the process-wide timer resolution. */
    HANDLE timer = CreateWaitableTimerExW(
        NULL, NULL, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
        TIMER_MODIFY_STATE | SYNCHRONIZE
    );
    if (timer) {
        LARGE_INTEGER due = {.QuadPart = -10000}; /* One millisecond. */
        bool armed = SetWaitableTimer(timer, &due, 0, NULL, NULL, FALSE);
        DWORD result = armed ? WaitForSingleObject(timer, 10) : WAIT_FAILED;
        /* Close before returning to Ruby, which may deliver an interrupt. */
        CloseHandle(timer);
        if (result != WAIT_FAILED) return NULL;
    }
    /* Ruby redirects Sleep to rb_w32_Sleep, which requires the GVL. */
    SleepEx(1, FALSE);
    return NULL;
}
#endif

/* Called only after releasing the container's native mutex. GC and scheduler
 * callbacks can run Ruby, mutate the container, or raise. The caller must
 * recheck its condition and original deadline after every return. */
void
containers_wait_without_descriptor(int error, const char *operation, bool *collected, VALUE timeout)
{
    if (error != EMFILE && error != ENFILE) {
        errno = error;
        rb_sys_fail(operation);
    }
    if (!*collected) {
        *collected = true;
        rb_gc_start();
        return;
    }

    /* Descriptor pressure must not turn a cooperative fiber wait into a
     * whole-thread block. Timed polling needs no new notification descriptor
     * and lets a producer on the same scheduler make progress. */
    double seconds = 0.001;
    if (!NIL_P(timeout)) {
        double remaining = NUM2DBL(timeout);
        if (remaining <= 0) return;
        if (remaining < seconds) seconds = remaining;
    }
    VALUE scheduler = rb_fiber_scheduler_current();
    if (!NIL_P(scheduler)) {
        rb_fiber_scheduler_kernel_sleep(scheduler, DBL2NUM(seconds));
    }
    else {
        struct timeval interval = {.tv_sec = 0, .tv_usec = (int)ceil(seconds * 1000000)};
        rb_thread_wait_for(interval);
    }
}

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

bool
containers_wait_for_readable(int fd, VALUE timeout)
{
#ifdef _WIN32
    /* Blocking CRT pipe reads do not reliably unblock on Thread#kill.
     * Use short no-GVL probes even for indefinite waits so Ruby can deliver
     * interrupts between slices and run the caller's waiter cleanup.
     * Scheduler-backed waits retain rb_io_wait integration. */
    if (NIL_P(rb_fiber_scheduler_current())) {
        double seconds = NIL_P(timeout) ? 0 : NUM2DBL(timeout);
        bool finite = !NIL_P(timeout);
        ULONGLONG deadline = GetTickCount64() + (ULONGLONG)ceil(seconds * 1000);
        containers_read_context_t context = {
            .fd = fd,
            .readable = false,
            .error = 0,
        };
        for (;;) {
            context.readable = false;
            context.error = 0;
            rb_thread_call_without_gvl(
                containers_poll_without_gvl,
                &context,
                NULL,
                NULL
            );
            if (context.error) {
                errno = context.error;
                rb_sys_fail("PeekNamedPipe");
            }
            if (context.readable) return true;
            if (finite && GetTickCount64() >= deadline) return false;
            containers_wait_safepoint();
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

#if RUBY_API_VERSION_CODE == 30400
static VALUE
farce_lock_native_thread(VALUE namespace)
{
    rb_thread_lock_native_thread();
    return Qnil;
}
#endif

RUBY_FUNC_EXPORTED void
Init_farce(void)
{
    rb_ext_ractor_safe(true);
    VALUE mFarce    = rb_const_get(rb_cObject, rb_intern("Farce"));
    VALUE mInternal = rb_const_get(mFarce, rb_intern("Internal"));
    VALUE singleton = rb_singleton_class(mInternal);
    eIsolationError = rb_const_get(rb_cRactor, rb_intern("IsolationError"));
#if RUBY_API_VERSION_CODE == 30400
    rb_define_singleton_method(mInternal, "lock_native_thread", farce_lock_native_thread, 0);
#endif
    rb_define_private_method(
        singleton,
        "load_native_fiber_scheduler",
        farce_load_native_fiber_scheduler,
        0
    );
    containers_init_transaction(mInternal);
    containers_init_atom(mInternal);
    containers_init_counter(mInternal);
    containers_init_exchanger(mInternal);
    containers_init_flag(mInternal);
    containers_init_lock(mInternal);
    containers_init_lru_maps(mInternal);
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
    containers_init_trie(mInternal);
}
