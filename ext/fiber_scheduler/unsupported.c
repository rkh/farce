#include "ruby.h"

void Init_fiber_scheduler(void) {
    rb_raise(rb_eLoadError, "native Farce fiber scheduling requires epoll or kqueue; use the select implementation");
}
