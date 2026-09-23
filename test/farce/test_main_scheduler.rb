# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestMainScheduler < Test
    def test_suite_teardown_stops_the_main_scheduler
      return unless Ractor.builtin?
      output, error, status = ruby_subprocess(<<~RUBY)
        require "minitest"
        # Minitest runs after_run callbacks in reverse registration order.
        Minitest.after_run do
          abort "main scheduler still running" unless Farce.on_main.state == :closed
          puts "main scheduler stopped"
        end
        require "setup"
        class MainSchedulerProbe < Test
          def test_main_scheduler_is_running
            assert_equal :running, Farce.on_main.state
          end
        end
      RUBY

      assert_predicate status, :success?, error
      assert_includes output, "main scheduler stopped"
      assert_empty error
    end
  end
end
