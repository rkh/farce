# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "mkmf"
require_relative "../ext_helper"

if RUBY_ENGINE != "ruby"
  File.write("Makefile", "all:\ninstall:\n")
  return
end

# rubocop:disable Style/GlobalVars -- mkmf configuration variables
%w[pthread.h ruby/ractor.h ruby/thread.h ruby/fiber/scheduler.h].each do |header|
  have_header(header) or abort "#{header} is required"
end

ruby_major, ruby_minor = RUBY_VERSION.split(".").first(2).map!(&:to_i)
ruby_api = (ruby_major * 100) + ruby_minor
if ruby_api >= 401
  have_macro("RB_OBJ_SET_SHAREABLE", "ruby/ractor.h") or abort "RB_OBJ_SET_SHAREABLE is required"
  $defs << "-DFARCE_HAVE_EXPORTED_SHAREABLE_MARKER"
elsif ruby_api >= 304
  # CRuby 3.4/4.0 have no exported marker on supported builds. The native
  # publisher rejects Ruby ivars and requires audited typed-data payloads.
  $defs << "-DFARCE_USE_LEGACY_SHAREABLE_FLAG"
else
  abort "Native unfrozen publication requires CRuby 3.4 or newer"
end

if ruby_api == 304
  have_func("rb_thread_lock_native_thread", "ruby/thread.h") or abort "rb_thread_lock_native_thread is required"
end

have_func("clock_gettime", "time.h")

if /mswin|mingw/ =~ RUBY_PLATFORM
  have_func("rb_objspace_reachable_objects_from") or abort "Windows waits require rb_objspace_reachable_objects_from"
end

if have_header("pthread/qos.h")
  have_func("pthread_set_qos_class_self_np", "pthread/qos.h")
  have_func("pthread_get_qos_class_np", "pthread/qos.h")
  have_func("qos_class_main", "pthread/qos.h")
end

have_func("sysctlbyname", "sys/sysctl.h") if have_header("sys/sysctl.h")

futex = false
if enable_config("futex", true) && RUBY_PLATFORM.include?("linux") &&
    have_header("linux/futex.h") && have_header("sys/syscall.h")
  futex = try_compile(<<~SOURCE)
    #include <linux/futex.h>
    #include <sys/syscall.h>
    #include <stdint.h>
    #include <stdatomic.h>
    #include <time.h>
    #include <unistd.h>

    _Static_assert(sizeof(_Atomic(uint32_t)) == 4, "32-bit futex word");
    _Static_assert(_Alignof(_Atomic(uint32_t)) >= 4, "aligned futex word");
    int main(void) {
        _Atomic(uint32_t) word = 1;
        struct timespec now;
        (void)clock_gettime(CLOCK_MONOTONIC, &now);
        (void)syscall(SYS_futex, &word, FUTEX_WAIT_PRIVATE, 0, 0, 0, 0);
        (void)syscall(SYS_futex, &word, FUTEX_WAKE_PRIVATE, 1, 0, 0, 0);
        return 0;
    }
  SOURCE
end
$defs << "-DFARCE_HAVE_FUTEX" if futex

epoll = have_header("sys/epoll.h")
kqueue = have_header("sys/event.h")
$srcs = %w[
  atom.c bounded_map.c counter.c darwin.c dict.c exchanger.c farce.c flag.c futex.c lock.c map.c native_wait.c
  priority_queue.c queue.c signal.c transaction.c tree_map.c trie.c unshareable.c unshared_signal.c vector.c weak_map.c
]
$srcs.concat(epoll || kqueue ? %w[drivers.c io.c reactor.c] : ["unsupported.c"])

if epoll || kqueue
  dir_config("uring")
  have_func("epoll_pwait2", "sys/epoll.h") if epoll
  have_func("rb_io_timeout", "ruby/io.h")
  if enable_config("io-uring", true) && have_header("liburing.h") && have_library("uring", "io_uring_queue_init")
    $defs << "-DFARCE_HAVE_LIBURING"
    $DLDFLAGS << " -Wl,--exclude-libs,liburing.a" if enable_config("uring-static", false)
    if futex && try_compile(<<~SOURCE)
      #include <linux/futex.h>
      #include <liburing.h>

      int main(void) {
          struct io_uring_sqe sqe;
          uint32_t word = 0;
          io_uring_prep_futex_wait(&sqe, &word, 0, FUTEX_BITSET_MATCH_ANY,
              FUTEX_32 | FUTEX_PRIVATE_FLAG, 0);
          return IORING_OP_FUTEX_WAIT == 0;
      }
    SOURCE
      $defs << "-DFARCE_HAVE_URING_FUTEX"
    end
  end
end

# The internal callback gained an object-space argument during Ruby 4.1
# development. Check its exact type, since incompatible assignments may only warn.
weak_callback_arguments = ["void *, void *", "void *"].find do |arguments|
  try_compile(<<~SOURCE)
    #include "ruby.h"

    _Static_assert(
        _Generic(((rb_data_type_t *)0)->function.handle_weak_references,
            void (*)(#{arguments}): 1, default: 0),
        "unsupported weak-reference callback"
    );

    int main(void) { return 0; }
  SOURCE
end

weak_declare = have_func("rb_gc_declare_weak_references")
weak_alive   = have_func("rb_gc_handle_weak_references_alive_p")

# Kazlib deliberately puts full-tree integrity walks behind assert(3).
# Enable them only while debugging the priority queue.
$defs << "-DNDEBUG" unless ENV["FARCE_PRIORITY_QUEUE_ASSERTIONS"] == "1"
if weak_callback_arguments && weak_declare && weak_alive
  $defs << "-DRC_HAVE_NATIVE_WEAK_REFERENCES=1"
  $defs << "-DFARCE_WEAK_REFERENCES_HAVE_OBJSPACE=1" if weak_callback_arguments == "void *, void *"
end
$defs << "-DFARCE_TRIE_FAILURE_INJECTION" if ENV["FARCE_TRIE_FAILURE_INJECTION"] == "1"
$CFLAGS  = "#{$CFLAGS} -std=c11 -fvisibility=hidden -Wall -Wextra -Wno-unused-parameter -Wno-unused-function"
$LDFLAGS = "#{$LDFLAGS} -pthread" unless /mswin|mingw/ =~ RUBY_PLATFORM

if ENV["FARCE_SCHEDULER_SANITIZE"]
  flags = " -O1 -g -fno-omit-frame-pointer -fsanitize=#{ENV.fetch("FARCE_SCHEDULER_SANITIZE")}"
  $CFLAGS << flags
  $LDFLAGS << flags
end

if try_cflags("-flto") && try_ldflags("-flto")
  $CFLAGS << " -flto"
  $LDFLAGS << " -flto"
end
create_makefile ExtHelper.ext_path("farce")
# rubocop:enable Style/GlobalVars
