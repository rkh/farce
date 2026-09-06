# frozen_string_literal: true

require "mkmf"
require_relative "../ext_helper"

if RUBY_ENGINE != "ruby"
  File.write("Makefile", "all:\ninstall:\n")
  return
end

%w[pthread.h ruby/ractor.h ruby/thread.h ruby/fiber/scheduler.h].each do |header|
  have_header(header) or abort "#{header} is required"
end

have_func("clock_gettime", "time.h")

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

# rubocop:disable Style/GlobalVars
# Kazlib deliberately puts full-tree integrity walks behind assert(3).
# Enable them only while debugging the priority queue.
$defs << "-DNDEBUG" unless ENV["FARCE_PRIORITY_QUEUE_ASSERTIONS"] == "1"
$defs << "-DRC_HAVE_NATIVE_WEAK_MAPS=1" if weak_callback && weak_declare && weak_alive
$CFLAGS  = "#{$CFLAGS} -Wall -Wextra -Wno-unused-parameter -Wno-unused-function"
$LDFLAGS = "#{$LDFLAGS} -pthread" unless /mswin|mingw/ =~ RUBY_PLATFORM
# rubocop:enable Style/GlobalVars

create_makefile ExtHelper.ext_path("containers")
