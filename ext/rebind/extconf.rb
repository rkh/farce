# frozen_string_literal: true

require "mkmf"
require_relative "../ext_helper"

if RUBY_ENGINE == "ruby"
  create_makefile ExtHelper.ext_path("rebind")
else
  File.write("Makefile", "all:\ninstall:\n")
end
