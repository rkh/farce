#include "native_wait.h"
#include "ruby/fiber/scheduler.h"

#include <errno.h>
#include <fcntl.h>
#include <time.h>
#include <unistd.h>

static double
waiter_monotonic_now(void)
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

static void
waiter_set_fd_flags(int fd)
{
#ifndef _WIN32
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) (void)fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    flags = fcntl(fd, F_GETFD, 0);
    if (flags >= 0) (void)fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
#endif
}

void
containers_waiter_init(containers_waiter_t *waiter)
{
    containers_futex_init(&waiter->futex);
    waiter->read_fd = waiter->write_fd = -1;
    waiter->mode = CONTAINERS_WAITER_PENDING;
    waiter->notified = false;
}

bool
containers_waiter_notify(containers_waiter_t *waiter)
{
    if (waiter->notified) return true;
    if (waiter->mode == CONTAINERS_WAITER_FUTEX) {
        waiter->notified = true;
        containers_futex_notify(&waiter->futex);
        return true;
    }

    /* A pending waiter has not selected its backend yet. Latch its wake so
     * setup can return immediately or a future kernel wait sees a mismatch. */
    atomic_store_explicit(&waiter->futex.value, 1, memory_order_release);
    if (waiter->mode == CONTAINERS_WAITER_PENDING) {
        waiter->notified = true;
        return true;
    }

    unsigned char byte = 1;
    ssize_t result;
    do {
        result = write(waiter->write_fd, &byte, 1);
    } while (result < 0 && errno == EINTR);
    if (result == 1 || (result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))) {
        waiter->notified = true;
    }
    return waiter->notified;
}

bool
containers_waiter_wait(
    containers_waiter_t *waiter,
    pthread_mutex_t *guard,
    bool finite,
    double deadline,
    int *pipe_error
)
{
    if (pipe_error) *pipe_error = 0;
    if (atomic_load_explicit(&waiter->futex.value, memory_order_acquire) == 1) return true;
    if (finite && deadline <= waiter_monotonic_now()) return false;

    /* Selection can enter Ruby or probe the kernel. The registration stays
     * pending, with no native container mutex held, throughout this work. */
    VALUE scheduler = rb_fiber_scheduler_current();
    /* Blocking futex waits failed the cross-core thread handoff performance
     * gate. Keep Ruby's managed IO path for threads and use futexes only when
     * the owning event loop can complete them asynchronously. */
    bool use_futex = !NIL_P(scheduler) && containers_futex_scheduler_supported(scheduler);

    int descriptors[2] = {-1, -1};
    if (!use_futex) {
        if (pipe(descriptors) != 0) {
            int error = errno;
            if (atomic_load_explicit(&waiter->futex.value, memory_order_acquire) == 1) return true;
            if (pipe_error) {
                *pipe_error = error;
                return false;
            }
            rb_syserr_fail(error, "pipe");
        }
        waiter_set_fd_flags(descriptors[0]);
        waiter_set_fd_flags(descriptors[1]);
    }

    /* No Ruby calls occur between creating descriptors and recording ownership.
     * A notifier either latches a pending wake or observes the complete backend. */
    if (guard) pthread_mutex_lock(guard);
    waiter->read_fd = descriptors[0];
    waiter->write_fd = descriptors[1];
    waiter->mode = use_futex ? CONTAINERS_WAITER_FUTEX : CONTAINERS_WAITER_IO;
    bool notified = waiter->notified;
    if (guard) pthread_mutex_unlock(guard);
    if (notified) return true;

    VALUE timeout = Qnil;
    if (finite) {
        double remaining = deadline - waiter_monotonic_now();
        if (remaining <= 0) {
            return atomic_load_explicit(&waiter->futex.value, memory_order_acquire) == 1;
        }
        timeout = DBL2NUM(remaining);
    }

    if (use_futex) {
        return containers_futex_scheduler_wait(scheduler, &waiter->futex, timeout);
    }
    return containers_wait_for_readable(waiter->read_fd, timeout);
}

void
containers_waiter_close(containers_waiter_t *waiter)
{
    if (waiter->read_fd >= 0) close(waiter->read_fd);
    if (waiter->write_fd >= 0) close(waiter->write_fd);
    waiter->read_fd = waiter->write_fd = -1;
}
