# frozen_string_literal: true

$VERBOSE = false if RUBY_ENGINE == "jruby"
require "bundler/setup" unless ENV["FARCE_STANDALONE_TESTS"] == "1"

if ENV["COVERAGE"] && ENV["COVERAGE"].downcase != "false"
  raise "Farce has been loaded before coverage tracking was enabled." if defined?(Farce::Clock)
  require "simplecov"
  SimpleCov.start
end

require "farce"

$LOAD_PATH.unshift(__dir__)

require "minitest/autorun"
require "minitest/reporters"

Minitest::Reporters.use!

module Helpers
  Internal = Farce.const_get(:Internal, false)
  include Internal::Autoloads["#{__dir__}/helpers"]
end

class Test < Minitest::Test
  include Helpers
end
