# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Helpers
  module IsolatedRuby
    include Subprocess

    # Run with fresh Ruby globals, constants, and loaded features. Use
    # ruby_subprocess for process signals, termination, or JVM startup options.
    # Return stdout, stderr, and a status with success? and exitstatus methods.
    def ruby_isolated(source, env: {}, timeout: Float(ENV.fetch("TEST_SUBPROCESS_TIMEOUT", 15)), coverage: true)
      return ruby_subprocess(source, env:, timeout:, coverage:) unless RUBY_ENGINE == "jruby"

      runner = JrubyRuntime.new(ruby_command(source, coverage:).drop(1), env:)
      output, error, status = runner.run(timeout:)
      if runner.timed_out?
        flunk <<~MESSAGE
          Isolated Ruby timed out after #{timeout} seconds
          stdout:
          #{output}
          stderr:
          #{error}
        MESSAGE
      end
      [output, error, status]
    end
  end
end
