#ifndef FARCE_NATIVE_WAIT_H
#define FARCE_NATIVE_WAIT_H

#include "containers.h"
#include "futex.h"

typedef enum {
    CONTAINERS_WAITER_PENDING,
    CONTAINERS_WAITER_FUTEX,
    CONTAINERS_WAITER_IO
} containers_waiter_mode_t;

typedef struct {
    containers_futex_t futex;
    int read_fd, write_fd;
    containers_waiter_mode_t mode;
    bool notified;
} containers_waiter_t;

/* Initialize before linking under the container's guard. Notification is
 * native-only and uses that same guard. A NULL guard denotes owner-local state. */
void containers_waiter_init(containers_waiter_t *waiter);
bool containers_waiter_notify(containers_waiter_t *waiter);
/* Run outside the guard and inside the caller's cleanup ensure. The absolute
 * monotonic deadline includes backend setup. Optional pipe_error lets callers
 * retain their own descriptor-pressure recovery; other errors raise normally. */
bool containers_waiter_wait(
    containers_waiter_t *waiter,
    pthread_mutex_t *guard,
    bool finite,
    double deadline,
    int *pipe_error
);
/* Unlink under the guard first. Waiting has already drained native requests. */
void containers_waiter_close(containers_waiter_t *waiter);

#endif
