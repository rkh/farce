#include "ruby.h"

void farce_init_fiber_scheduler(VALUE internal) {
    (void)internal;
    rb_raise(rb_eLoadError, "native Farce fiber scheduling requires epoll or kqueue; use the select implementation");
}
