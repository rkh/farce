# frozen_string_literal: true

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

epoll = have_header("sys/epoll.h")
kqueue = have_header("sys/event.h")
$srcs = %w[
  atom.c bounded_map.c counter.c darwin.c dict.c exchanger.c farce.c flag.c lock.c map.c priority_queue.c
  queue.c signal.c tree_map.c trie.c unshareable.c unshared_signal.c vector.c weak_map.c
]
$srcs.concat(epoll || kqueue ? %w[drivers.c io.c reactor.c] : ["unsupported.c"])

if epoll || kqueue
  have_func("epoll_pwait2", "sys/epoll.h") if epoll
  have_func("rb_io_timeout", "ruby/io.h")
  if enable_config("io-uring", true) && have_header("liburing.h") && have_library("uring", "io_uring_queue_init")
    $defs << "-DFARCE_HAVE_LIBURING"
  end
end

weak_callback = try_compile(<<~SOURCE)
  #include "ruby.h"

  static void handle_weak_references(void *pointer) { (void)pointer; }
  static const rb_data_type_t probe_type = {
      .wrap_struct_name = "weak-reference-probe",
      .function = {
          .handle_weak_references = handle_weak_references,
      },
  };

  int main(void) { return probe_type.function.handle_weak_references == 0; }
SOURCE

weak_declare = have_func("rb_gc_declare_weak_references")
weak_alive   = have_func("rb_gc_handle_weak_references_alive_p")

# Kazlib deliberately puts full-tree integrity walks behind assert(3).
# Enable them only while debugging the priority queue.
$defs << "-DNDEBUG" unless ENV["FARCE_PRIORITY_QUEUE_ASSERTIONS"] == "1"
$defs << "-DRC_HAVE_NATIVE_WEAK_REFERENCES=1" if weak_callback && weak_declare && weak_alive
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
