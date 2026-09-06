# frozen_string_literal: true
# rubocop:disable Style/GlobalVars -- mkmf configuration variables
require "mkmf"
require_relative "../ext_helper"
if RUBY_ENGINE != "ruby"
  File.write("Makefile", "all:\ninstall:\n")
  exit
end
unless have_header("sys/epoll.h") || have_header("sys/event.h")
  $srcs = ["unsupported.c"]
  create_makefile ExtHelper.ext_path("fiber_scheduler")
  exit
end
$srcs = %w[reactor.c drivers.c io.c]
have_func("epoll_pwait2", "sys/epoll.h") if have_header("sys/epoll.h")
have_func("rb_io_timeout", "ruby/io.h")
if enable_config("io-uring", true) && have_header("liburing.h") && have_library("uring", "io_uring_queue_init")
  $defs << "-DFARCE_HAVE_LIBURING"
end
$CFLAGS << " -std=c11 -fvisibility=hidden -Wall -Wextra -Wno-unused-parameter"
if ENV["FARCE_SCHEDULER_SANITIZE"]
  flags = " -O1 -g -fno-omit-frame-pointer -fsanitize=#{ENV.fetch("FARCE_SCHEDULER_SANITIZE")}"
  $CFLAGS << flags
  $LDFLAGS << flags
end
if try_cflags("-flto") && try_ldflags("-flto")
  $CFLAGS << " -flto"
  $LDFLAGS << " -flto"
end
create_makefile ExtHelper.ext_path("fiber_scheduler")

# rubocop:enable Style/GlobalVars
