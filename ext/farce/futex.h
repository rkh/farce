#ifndef FARCE_FUTEX_H
#define FARCE_FUTEX_H

#include "ruby.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdatomic.h>

/* Each registered waiter owns this word until all native waits have ended. */
typedef struct {
    _Atomic(uint32_t) value;
} containers_futex_t;

_Static_assert(sizeof(containers_futex_t) == 4, "a futex word must contain exactly 32 bits");
_Static_assert(_Alignof(containers_futex_t) >= 4, "a futex word must be four-byte aligned");

/* Call without native container locks. Unsupported builds and kernels return false. */
bool containers_futex_available(void);
/* These two operations are native-only and may run under a container mutex. */
void containers_futex_init(containers_futex_t *futex);
void containers_futex_notify(containers_futex_t *futex);

/* Scheduler support is opt-in and never blocks an unsupported event loop. */
bool containers_futex_scheduler_supported(VALUE scheduler);
/* True requests a condition/deadline recheck after notification or backend
 * rejection. False means the scheduler timer expired. Every caller still
 * rechecks synchronized state and its original absolute deadline. */
bool containers_futex_scheduler_wait(VALUE scheduler, containers_futex_t *futex, VALUE timeout);

#endif
