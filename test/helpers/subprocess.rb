# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "open3"
require "rbconfig"

module Helpers
  module Subprocess
    def require_subprocess_support
      return unless RUBY_ENGINE == "truffleruby" && !TruffleRuby.native?
      skip "Subprocess tests are disabled on TruffleRuby+GraalVM"
    end

    # Build a command without loading Farce or the test framework in the child.
    # Disable coverage for probes whose startup time is part of the test.
    def ruby_command(source, coverage: true)
      require_subprocess_support

      command = [RbConfig.ruby, "-I#{File.expand_path("../../lib", __dir__)}", "-I#{File.expand_path("..", __dir__)}"]
      # Enable accurate coverage even when the child starts SimpleCov itself.
      command << "--debug" if RUBY_ENGINE == "jruby"
      if coverage && ENV["COVERAGE"] && ENV["COVERAGE"].downcase != "false"
        command << "-r#{File.expand_path("../coverage_subprocess.rb", __dir__)}"
      end
      command.push("-e", source)
    end

    # Return stdout, stderr and Process::Status. Drain both pipes while waiting
    # so a verbose child cannot deadlock. Report captured output on timeout.
    def ruby_subprocess(source, env: {}, timeout: Float(ENV.fetch("TEST_SUBPROCESS_TIMEOUT", 15)), coverage: true)
      Open3.popen3(env, *ruby_command(source, coverage:)) do |input, output, error, waiter|
        input.close
        output_reader = Thread.new { output.read }
        error_reader = Thread.new { error.read }
        unless waiter.join(timeout)
          begin
            Process.kill("KILL", waiter.pid)
          rescue Errno::ESRCH
            # The child exited between the timeout and the kill.
          end
          waiter.join

          flunk <<~MESSAGE
            Ruby subprocess timed out after #{timeout} seconds
            stdout:
            #{output_reader.value}
            stderr:
            #{error_reader.value}
          MESSAGE
        end
        [output_reader.value, error_reader.value, waiter.value]
      end
    end
  end
end
