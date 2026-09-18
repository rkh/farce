#include "containers.h"
#include "ruby/fiber/scheduler.h"
#include "ruby/io.h"

#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

static VALUE cLock;

typedef struct containers_lock_waiter containers_lock_waiter_t;

struct containers_lock_waiter {
    int read_fd;
    int write_fd;
    bool notified;
    containers_lock_waiter_t *next;
};

typedef struct {
    pthread_mutex_t guard;
    VALUE owner;
    VALUE owner_thread;
    containers_lock_waiter_t *waiters;
    containers_lock_waiter_t *last_waiter;
    bool initialized;
} containers_lock_t;

typedef struct {
    containers_lock_t *lock;
    containers_lock_waiter_t waiter;
    bool completed;
} containers_lock_wait_context_t;

typedef struct {
    VALUE self;
    bool acquired;
} containers_lock_synchronize_context_t;

typedef struct {
    VALUE self;
    int argc;
    const VALUE *argv;
    bool released;
} containers_lock_sleep_context_t;

typedef struct {
    VALUE self;
    bool acquired;
    containers_lock_operation_t operation;
    VALUE opaque;
} containers_lock_call_context_t;

static void
containers_lock_set_fd_flags(int fd)
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

/* Called with lock->guard held. Mutex wakeups only need to make one waiter
 * runnable; the selected waiter remains linked until its ensure cleanup. */
static void
containers_lock_notify_one_locked(containers_lock_t *lock)
{
    unsigned char byte = 1;
    for (containers_lock_waiter_t *waiter = lock->waiters; waiter; waiter = waiter->next) {
        if (waiter->notified) continue;
        ssize_t result;
        do {
            result = write(waiter->write_fd, &byte, 1);
        } while (result < 0 && errno == EINTR);
        if (result == 1 || (result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))) {
            waiter->notified = true;
            return;
        }
    }
}

static void
containers_lock_mark(void *pointer)
{
    containers_lock_t *lock = pointer;
    rb_gc_mark_movable(lock->owner);
    rb_gc_mark_movable(lock->owner_thread);
}

static void
containers_lock_compact(void *pointer)
{
    containers_lock_t *lock = pointer;
    lock->owner = rb_gc_location(lock->owner);
    lock->owner_thread = rb_gc_location(lock->owner_thread);
}

static void
containers_lock_free(void *pointer)
{
    containers_lock_t *lock = pointer;
    pthread_mutex_destroy(&lock->guard);
    ruby_xfree(lock);
}

static size_t
containers_lock_memsize(const void *pointer)
{
    return pointer ? sizeof(containers_lock_t) : 0;
}

static const rb_data_type_t containers_lock_type = {
    .wrap_struct_name = "Ractor::Containers::Lock",
    .function = {
        .dmark = containers_lock_mark,
        .dfree = containers_lock_free,
        .dsize = containers_lock_memsize,
        .dcompact = containers_lock_compact,
    },
    .flags = RUBY_TYPED_FROZEN_SHAREABLE,
};

static VALUE
containers_lock_allocate(VALUE klass)
{
    containers_lock_t *lock;
    VALUE object = TypedData_Make_Struct(klass, containers_lock_t, &containers_lock_type, lock);
    pthread_mutex_init(&lock->guard, NULL);
    lock->owner = Qnil;
    lock->owner_thread = Qnil;
    lock->waiters = NULL;
    lock->last_waiter = NULL;
    lock->initialized = false;
    return object;
}

static containers_lock_t *
containers_lock_get(VALUE self)
{
    containers_lock_t *lock;
    TypedData_Get_Struct(self, containers_lock_t, &containers_lock_type, lock);
    if (!lock->initialized) rb_raise(rb_eRuntimeError, "uninitialized Lock");
    return lock;
}

static VALUE
containers_lock_initialize(VALUE self)
{
    containers_lock_t *lock;
    TypedData_Get_Struct(self, containers_lock_t, &containers_lock_type, lock);
    if (lock->initialized) rb_raise(rb_eRuntimeError, "Lock is already initialized");
    rb_check_frozen(self);
    lock->initialized = true;
    containers_finish_initialization(self);
    return self;
}

static bool
containers_lock_wait_for_descriptor(int fd)
{
    return containers_wait_for_readable(fd, Qnil);
}

static VALUE
containers_lock_wait_body(VALUE opaque)
{
    containers_lock_wait_context_t *context = (containers_lock_wait_context_t *)opaque;
    bool awakened = containers_lock_wait_for_descriptor(context->waiter.read_fd);
    context->completed = true;
    return awakened ? Qtrue : Qfalse;
}

static VALUE
containers_lock_wait_cleanup(VALUE opaque)
{
    containers_lock_wait_context_t *context = (containers_lock_wait_context_t *)opaque;
    containers_lock_waiter_t *previous = NULL;
    containers_lock_waiter_t **link;

    pthread_mutex_lock(&context->lock->guard);
    for (link = &context->lock->waiters; *link; link = &(*link)->next) {
        if (*link == &context->waiter) {
            *link = context->waiter.next;
            if (context->lock->last_waiter == &context->waiter) {
                context->lock->last_waiter = previous;
            }
            break;
        }
        previous = *link;
    }
    if (!context->completed && context->waiter.notified && NIL_P(context->lock->owner)) {
        containers_lock_notify_one_locked(context->lock);
    }
    pthread_mutex_unlock(&context->lock->guard);
    close(context->waiter.read_fd);
    close(context->waiter.write_fd);
    return Qnil;
}

/* Called with lock->guard held and always returns with it released. */
static void
containers_lock_wait_once(containers_lock_t *lock)
{
    int descriptors[2];
    if (pipe(descriptors) != 0) {
        pthread_mutex_unlock(&lock->guard);
        rb_sys_fail("pipe");
    }
    containers_lock_set_fd_flags(descriptors[0]);
    containers_lock_set_fd_flags(descriptors[1]);

    containers_lock_wait_context_t context = {
        .lock = lock,
        .waiter = {
            .read_fd = descriptors[0],
            .write_fd = descriptors[1],
            .notified = false,
            .next = NULL,
        },
        .completed = false,
    };
    if (lock->last_waiter) lock->last_waiter->next = &context.waiter;
    else lock->waiters = &context.waiter;
    lock->last_waiter = &context.waiter;
    pthread_mutex_unlock(&lock->guard);
    (void)rb_ensure(
        containers_lock_wait_body,
        (VALUE)&context,
        containers_lock_wait_cleanup,
        (VALUE)&context
    );
}

static void
containers_lock_acquire(VALUE self)
{
    containers_lock_t *lock = containers_lock_get(self);
    VALUE current = rb_fiber_current();
    VALUE scheduler = rb_fiber_scheduler_current();
    VALUE current_thread = rb_thread_current();

    for (;;) {
        pthread_mutex_lock(&lock->guard);
        if (lock->owner == current) {
            pthread_mutex_unlock(&lock->guard);
            rb_raise(rb_eThreadError, "deadlock; recursive locking");
        }
        if (NIL_P(lock->owner)) {
            lock->owner = current;
            lock->owner_thread = current_thread;
            pthread_mutex_unlock(&lock->guard);
            return;
        }
        if (lock->owner_thread == current_thread && NIL_P(scheduler)) {
            pthread_mutex_unlock(&lock->guard);
            rb_raise(
                rb_eThreadError,
                "deadlock; lock already owned by another fiber belonging to the same thread"
            );
        }
        containers_lock_wait_once(lock);
    }
}

static void
containers_lock_release(VALUE self)
{
    containers_lock_t *lock = containers_lock_get(self);
    VALUE current = rb_fiber_current();

    pthread_mutex_lock(&lock->guard);
    if (NIL_P(lock->owner)) {
        pthread_mutex_unlock(&lock->guard);
        rb_raise(rb_eThreadError, "Attempt to unlock a mutex which is not locked");
    }
    if (lock->owner != current) {
        pthread_mutex_unlock(&lock->guard);
        rb_raise(rb_eThreadError, "Attempt to unlock a mutex which is locked by another thread/fiber");
    }
    lock->owner = Qnil;
    lock->owner_thread = Qnil;
    containers_lock_notify_one_locked(lock);
    pthread_mutex_unlock(&lock->guard);
}

static VALUE
containers_lock_lock(VALUE self)
{
    containers_lock_acquire(self);
    return self;
}

static VALUE
containers_lock_try_lock(VALUE self)
{
    containers_lock_t *lock = containers_lock_get(self);
    VALUE current = rb_fiber_current();
    bool acquired = false;

    pthread_mutex_lock(&lock->guard);
    if (NIL_P(lock->owner)) {
        lock->owner = current;
        lock->owner_thread = rb_thread_current();
        acquired = true;
    }
    pthread_mutex_unlock(&lock->guard);
    return acquired ? Qtrue : Qfalse;
}

static VALUE
containers_lock_unlock(VALUE self)
{
    containers_lock_release(self);
    return self;
}

static VALUE
containers_lock_locked_p(VALUE self)
{
    containers_lock_t *lock = containers_lock_get(self);
    bool locked;
    pthread_mutex_lock(&lock->guard);
    locked = !NIL_P(lock->owner);
    pthread_mutex_unlock(&lock->guard);
    return locked ? Qtrue : Qfalse;
}

static VALUE
containers_lock_owned_p(VALUE self)
{
    containers_lock_t *lock = containers_lock_get(self);
    VALUE current = rb_fiber_current();
    bool owned;
    pthread_mutex_lock(&lock->guard);
    owned = lock->owner == current;
    pthread_mutex_unlock(&lock->guard);
    return owned ? Qtrue : Qfalse;
}

static VALUE
containers_lock_synchronize_body(VALUE opaque)
{
    containers_lock_synchronize_context_t *context =
        (containers_lock_synchronize_context_t *)opaque;
    containers_lock_acquire(context->self);
    context->acquired = true;
    return rb_yield_values(0);
}

static VALUE
containers_lock_synchronize_cleanup(VALUE opaque)
{
    containers_lock_synchronize_context_t *context =
        (containers_lock_synchronize_context_t *)opaque;
    if (context->acquired) containers_lock_release(context->self);
    return Qnil;
}

static VALUE
containers_lock_synchronize(VALUE self)
{
    if (!rb_block_given_p()) rb_raise(rb_eThreadError, "must be called with a block");
    containers_lock_synchronize_context_t context = {.self = self, .acquired = false};
    return rb_ensure(
        containers_lock_synchronize_body,
        (VALUE)&context,
        containers_lock_synchronize_cleanup,
        (VALUE)&context
    );
}

static VALUE
containers_lock_call_body(VALUE opaque)
{
    containers_lock_call_context_t *context =
        (containers_lock_call_context_t *)opaque;
    containers_lock_acquire(context->self);
    context->acquired = true;
    return context->operation(context->opaque);
}

static VALUE
containers_lock_call_cleanup(VALUE opaque)
{
    containers_lock_call_context_t *context =
        (containers_lock_call_context_t *)opaque;
    if (context->acquired) containers_lock_release(context->self);
    return Qnil;
}

VALUE
containers_lock_new(void)
{
    return rb_class_new_instance(0, NULL, cLock);
}

VALUE
containers_lock_synchronize_call(
    VALUE lock,
    containers_lock_operation_t operation,
    VALUE opaque
)
{
    containers_lock_call_context_t call = {
        .self = lock,
        .acquired = false,
        .operation = operation,
        .opaque = opaque,
    };

    return rb_ensure(
        containers_lock_call_body,
        (VALUE)&call,
        containers_lock_call_cleanup,
        (VALUE)&call
    );
}

static VALUE
containers_lock_sleep_body(VALUE opaque)
{
    containers_lock_sleep_context_t *context = (containers_lock_sleep_context_t *)opaque;
    containers_lock_release(context->self);
    context->released = true;
    (void)rb_funcallv(rb_mKernel, rb_intern("sleep"), context->argc, context->argv);
    return Qnil;
}

static VALUE
containers_lock_sleep_cleanup(VALUE opaque)
{
    containers_lock_sleep_context_t *context = (containers_lock_sleep_context_t *)opaque;
    if (context->released) containers_lock_acquire(context->self);
    return Qnil;
}

static VALUE
containers_lock_sleep(int argc, VALUE *argv, VALUE self)
{
    rb_check_arity(argc, 0, 1);
    containers_lock_sleep_context_t context = {
        .self = self,
        .argc = argc,
        .argv = argv,
        .released = false,
    };
    return rb_ensure(
        containers_lock_sleep_body,
        (VALUE)&context,
        containers_lock_sleep_cleanup,
        (VALUE)&context
    );
}

void
containers_init_lock(VALUE namespace)
{
    cLock = rb_define_class_under(namespace, "Lock", rb_cObject);
    rb_define_alloc_func(cLock, containers_lock_allocate);
    rb_define_method(cLock, "initialize", containers_lock_initialize, 0);
    rb_define_method(cLock, "lock", containers_lock_lock, 0);
    rb_define_method(cLock, "locked?", containers_lock_locked_p, 0);
    rb_define_method(cLock, "owned?", containers_lock_owned_p, 0);
    rb_define_method(cLock, "sleep", containers_lock_sleep, -1);
    rb_define_method(cLock, "synchronize", containers_lock_synchronize, 0);
    rb_define_method(cLock, "try_lock", containers_lock_try_lock, 0);
    rb_define_method(cLock, "unlock", containers_lock_unlock, 0);
}
