# frozen_string_literal: true

return unless RUBY_ENGINE == "ruby"

require_relative "../../setup"

module Farce
  module Internal
    class YieldingPriority
      include Comparable

      attr_reader :rank

      def initialize(rank, yield_fiber: false)
        @rank = rank
        @yield_fiber = yield_fiber
        freeze
      end

      def <=>(other)
        Fiber.scheduler&.kernel_sleep(0.01) if @yield_fiber
        rank <=> other.rank
      end
    end

    class TransferringPriority
      include Comparable

      FIBER_KEY = :farce_priority_queue_reentry_fiber
      RESULT_KEY = :farce_priority_queue_reentry_result

      attr_reader :rank

      def initialize(rank, transfer: false)
        @rank = rank
        @transfer = transfer
        freeze
      end

      def <=>(other)
        if @transfer && (fiber = Thread.current[FIBER_KEY])
          Thread.current[FIBER_KEY] = nil
          Thread.current[RESULT_KEY] = fiber.resume
        end
        rank <=> other.rank
      end
    end

    class PriorityQueueWaitCancellation < StandardError; end

    class CancellingPriorityQueueScheduler < Helpers::QueueTestScheduler
      def cancel_next_io_wait!
        @cancel_next_io_wait = true
      end

      def io_wait(...)
        result = super
        if @cancel_next_io_wait
          @cancel_next_io_wait = false
          raise PriorityQueueWaitCancellation, "cancel notified waiter"
        end
        result
      end

      def run_once = send(:run)

      def waiting_io_ready?
        descriptors = instance_variable_get(:@readable).keys
        !!IO.select(descriptors, nil, nil, 0)&.first&.any?
      end
    end

    class TestPriorityQueueStorageFiberScheduler < Test
      def setup
        skip "Fiber schedulers are not supported" unless Fiber.respond_to?(:set_scheduler)
      end

      def teardown
        Fiber.set_scheduler(nil) if Fiber.respond_to?(:scheduler) && Fiber.scheduler
      end

      def test_comparator_contention_parks_only_the_waiting_fiber
        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        queue = PriorityQueue.new
        queue.push(YieldingPriority.new(1), :first)
        events = []

        Fiber.schedule do
          events << :push_started
          queue.push(YieldingPriority.new(2, yield_fiber: true), :second)
          events << :pushed
        end
        Fiber.schedule do
          events << :peek_started
          events << queue.peek
        end
        Fiber.set_scheduler(nil)

        assert_equal %i[push_started peek_started pushed first], events
        assert_operator scheduler.io_wait_calls, :>=, 1
      end

      def test_unscheduled_fiber_reentry_raises_instead_of_blocking_the_thread
        queue = PriorityQueue.new
        queue.push(TransferringPriority.new(1), :first)
        Thread.current[TransferringPriority::FIBER_KEY] = Fiber.new do
          queue.peek
        rescue StandardError => e
          e
        end

        queue.push(TransferringPriority.new(2, transfer: true), :second)
        error = Thread.current[TransferringPriority::RESULT_KEY]

        assert_instance_of ThreadError, error
        assert_match(/unscheduled fibers/, error.message)
        assert_equal :first, queue.pop
        assert_equal :second, queue.pop
      ensure
        Thread.current[TransferringPriority::FIBER_KEY] = nil
        Thread.current[TransferringPriority::RESULT_KEY] = nil
      end

      def test_canceling_the_notified_storage_lock_waiter_wakes_the_next_fiber
        scheduler = CancellingPriorityQueueScheduler.new
        Fiber.set_scheduler(scheduler)
        queue = PriorityQueue.new
        queue.push(YieldingPriority.new(1), :first)
        events = []
        scheduler.cancel_next_io_wait!

        Fiber.schedule do
          events << :owner_started
          queue.push(YieldingPriority.new(2, yield_fiber: true), :second)
          events << :owner_finished
        end
        Fiber.schedule do
          events << :canceled_started
          queue.peek
        rescue PriorityQueueWaitCancellation
          events << :canceled
        end
        Fiber.schedule do
          events << :survivor_started
          events << queue.peek
        end

        4.times do
          break if events.include?(:canceled)

          Timeout.timeout(1) { scheduler.run_once }
        end

        assert_includes events, :canceled
        assert_predicate scheduler, :waiting_io_ready?, "the next storage-lock waiter was stranded"

        scheduler.run_once

        assert_equal :first, events.last
        Fiber.set_scheduler(nil)
      end
    end
  end
end
