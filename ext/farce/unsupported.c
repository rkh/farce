#include "futex.h"

void farce_init_fiber_scheduler(VALUE internal) {
    (void)internal;
    rb_raise(rb_eLoadError, "native Farce fiber scheduling requires epoll or kqueue; use the select implementation");
}

bool containers_futex_scheduler_supported(VALUE scheduler) {
    (void)scheduler;
    return false;
}

bool containers_futex_scheduler_wait(VALUE scheduler, containers_futex_t *word, VALUE timeout) {
    (void)scheduler;
    (void)word;
    (void)timeout;
    return true;
}
