# frozen_string_literal: true

require "mkmf"
require_relative "../ext_helper"

if RUBY_ENGINE == "jruby"
  File.write("Makefile", "all:\ninstall:\n")
else
  have_func("rb_safe_level", "ruby.h")
  create_makefile ExtHelper.ext_path("rbtree")
end
