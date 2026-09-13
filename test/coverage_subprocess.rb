# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# The subprocess helper loads this before scripts can require Farce.
return unless ENV["COVERAGE"] && ENV["COVERAGE"].downcase != "false"

require "simplecov"
SimpleCov.start do
  command_name "#{command_name} subprocess #{Process.pid}"
  formatters []
  print_errors false
end
