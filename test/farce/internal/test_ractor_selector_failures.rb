# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

return unless RUBY_ENGINE == "ruby"
require_relative "../../setup"

module Farce
  module Internal
    class TestRactorSelectorFailures < Test
      class FailingSelector < RactorSelector
        attr_reader :entered, :release, :submitted, :validating, :validated, :injected_failure
        attr_accessor :pause_validation

        def initialize
          @entered = Thread::Queue.new
          @release = Thread::Queue.new
          @submitted = Thread::Queue.new
          @validating = Thread::Queue.new
          @validated = Thread::Queue.new
          @injected_failure = RuntimeError.new("selector helper failed")
          super
        end

        private

        def command(action, ...)
          super
          @submitted << true if action == :add
        end

        def validate_source(source)
          super
          return unless @pause_validation
          @validating << true
          @validated.pop
        end

        def dispatch_buffer
          # Keep injected failures quiet on versions without the reporting workaround.
          Thread.current.report_on_exception = false
          @entered << true
          @release.pop
          raise @injected_failure
        end
      end

      def test_exception_reporting_policy_is_limited_to_the_ruby41_helper
        reporting = Thread.report_on_exception
        selector = RactorSelector.new
        selector.ractor_receive(::Ractor.current, timeout: 0)

        helper_reporting = selector.instance_variable_get(:@thread).report_on_exception

        assert_equal RUBY_VERSION.start_with?("4.1.") ? false : reporting, helper_reporting
        assert_equal reporting, Thread.report_on_exception
        assert_equal reporting, Thread.new { Thread.current.report_on_exception }.value
      ensure
        selector&.close
      end

      def test_helper_failure_reaches_pending_queued_and_late_callers
        selector = FailingSelector.new
        clients = []
        call = proc do
          selector.ractor_receive(::Ractor.current)
        rescue StandardError => e
          e
        end

        clients << Thread.new(&call)
        selector.entered.pop
        selector.submitted.pop
        clients << Thread.new(&call)
        selector.submitted.pop

        # This caller has passed the closed check but has not enqueued its command.
        selector.pause_validation = true
        clients << Thread.new(&call)
        selector.validating.pop
        selector.release << true

        assert clients[0].join(2), "pending caller was stranded"
        assert clients[1].join(2), "queued caller was stranded"
        selector.validated << true

        assert clients[2].join(2), "late caller was stranded"

        clients.each { |client| assert_same selector.injected_failure, client.value }
        assert_same selector.injected_failure, assert_raises(RuntimeError) { selector.ractor_receive(::Ractor.current) }
        2.times { assert_same selector.injected_failure, assert_raises(RuntimeError) { selector.close } }
      ensure
        selector&.release&.push(true)
        selector&.validated&.push(true)
        clients&.each { |client| client.kill.join }
        begin
          selector&.close
        rescue RuntimeError
          # The failure was checked above.
        end
      end

      def test_ruby41_helper_does_not_report_exceptions_during_ractor_teardown
        return unless RUBY_VERSION.start_with?("4.1.")

        output, error, status = ruby_isolated(<<~RUBY, timeout: 10)
          require "farce"
          class TeardownSelector < Farce.const_get(:Internal)::RactorSelector
            private def cleanup_control = Object.new.missing_method_during_teardown
          end
          worker = ::Ractor.new do
            selector = TeardownSelector.new
            selector.ractor_receive(::Ractor.current, timeout: 0)
            :done
          end
          raise "wrong result" unless worker.value == :done
          puts "ok"
        RUBY

        assert_predicate status, :success?, error
        assert_equal "ok\n", output
        assert_empty error
      end
    end
  end
end
