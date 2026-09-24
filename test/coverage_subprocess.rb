# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# The subprocess helper loads this before scripts can require Farce.
return unless ENV["COVERAGE"] && ENV["COVERAGE"].downcase != "false"

# Select locked gem versions before SimpleCov can activate default gems.
require "bundler/setup"
require "simplecov"
SimpleCov.start do
  identifier = Process.pid.to_s
  if RUBY_ENGINE == "jruby"
    require "jruby"
    identifier += " runtime #{JRuby.runtime.runtime_number}"
  end
  command_name "#{command_name} subprocess #{identifier}"
  formatters []
  print_errors false
end
