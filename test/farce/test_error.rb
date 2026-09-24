# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestError < Test
    def test_error_hierarchy
      assert_equal ::ClosedQueueError, ClosedQueueError.superclass
      assert_equal ClosedQueueError, SealedQueueError.superclass
      assert_equal StandardError, SchedulerClosedError.superclass
      assert_equal SchedulerClosedError, PoolClosedError.superclass
    end

    def test_old_error_names_are_not_defined
      refute Queue.const_defined?(:ClosedError, false)
      refute Queue.const_defined?(:SealedError, false)
      refute Scheduler.const_defined?(:ClosedError, false)
      refute Pool.const_defined?(:ClosedError, false)
    end

    def test_internal_queue_errors_do_not_load_the_public_queue
      output, error, status = ruby_isolated(<<~RUBY,
        require "farce"
        path = Farce.autoload?(:Queue)
        abort "public queue already loaded" unless path
        queue = Farce.const_get(:Internal, false)::Queue.new
        queue.push(:value)
        queue.seal
        begin
          queue.push(:rejected)
          abort "sealed queue accepted a push"
        rescue Farce::SealedQueueError
        end
        abort "lost queued value" unless queue.pop == :value
        begin
          queue.pop
          abort "closed queue accepted a pop"
        rescue Farce::ClosedQueueError
        end
        abort "public queue was loaded" unless Farce.autoload?(:Queue) == path
        puts "ok"
      RUBY
                                           )

      assert_predicate status, :success?, error
      assert_equal "ok\n", output
    end
  end
end
