#include "futex.h"

#include <errno.h>

#ifdef FARCE_HAVE_FUTEX
#include <linux/futex.h>
#include <pthread.h>
#include <sys/syscall.h>
#include <unistd.h>

enum { FUTEX_WAITING = 0, FUTEX_NOTIFIED = 1 };

static pthread_once_t futex_probe_once = PTHREAD_ONCE_INIT;
static int futex_probe_error;
static bool futex_supported;

static bool
futex_unsupported_error(int error)
{
    return error == ENOSYS || error == EPERM || error == EACCES || error == EOPNOTSUPP;
}

static void
futex_probe(void)
{
    containers_futex_t futex;
    atomic_init(&futex.value, FUTEX_NOTIFIED);
    /* The mismatch never sleeps, including on kernels without futex support. */
    long result = syscall(SYS_futex, &futex.value, FUTEX_WAIT_PRIVATE,
        FUTEX_WAITING, NULL, NULL, 0);
    if (result != -1 || errno != EAGAIN) {
        futex_probe_error = result == -1 ? errno : EIO;
        return;
    }
    result = syscall(SYS_futex, &futex.value, FUTEX_WAKE_PRIVATE, 1, NULL, NULL, 0);
    if (result < 0) {
        futex_probe_error = errno;
        return;
    }
    futex_supported = true;
}

#endif

bool
containers_futex_available(void)
{
#ifdef FARCE_HAVE_FUTEX
    int error = pthread_once(&futex_probe_once, futex_probe);
    if (error) rb_syserr_fail(error, "pthread_once");
    if (futex_probe_error && !futex_unsupported_error(futex_probe_error)) {
        rb_syserr_fail(futex_probe_error, "futex capability probe");
    }
    return futex_supported;
#else
    return false;
#endif
}

void
containers_futex_init(containers_futex_t *futex)
{
    atomic_init(&futex->value, 0);
}

void
containers_futex_notify(containers_futex_t *futex)
{
    atomic_store_explicit(&futex->value, 1, memory_order_release);
#ifdef FARCE_HAVE_FUTEX
    int saved_errno = errno;
    while (syscall(SYS_futex, &futex->value, FUTEX_WAKE_PRIVATE,
        1, NULL, NULL, 0) < 0 && errno == EINTR) {}
    errno = saved_errno;
#endif
}
