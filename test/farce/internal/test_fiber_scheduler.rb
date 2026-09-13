# frozen_string_literal: true

return unless Fiber.respond_to?(:set_scheduler)
require_relative "../../setup"

module Farce
  module Internal
    class TestFiberScheduler < Test
      include Helpers::InternalTestHelpers

      def teardown
        Fiber.set_scheduler(nil) if Fiber.respond_to?(:scheduler) && Fiber.scheduler
      end

      def test_blocked_pop_does_not_block_another_fiber
        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        queue = Queue.new
        events = []

        Fiber.schedule do
          events << :pop_started
          events << queue.pop
        end
        Fiber.schedule do
          events << :producer_ran
          queue.push(:value)
        end
        Fiber.set_scheduler(nil)

        assert_equal %i[pop_started producer_ran value], events
        assert_operator scheduler.io_wait_calls, :>=, 1
      end

      def test_blocked_push_does_not_block_another_fiber
        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        queue = Queue.new(capacity: 1)
        queue.push(:first)
        events = []

        Fiber.schedule do
          events << :push_started
          events << queue.push(:second)
        end
        Fiber.schedule do
          events << queue.pop
        end
        Fiber.set_scheduler(nil)

        assert_equal [:push_started, :first, true], events
        assert_equal :second, queue.pop
        assert_operator scheduler.io_wait_calls, :>=, 1
      end

      def test_timeout_does_not_block_another_fiber
        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        queue = Queue.new
        events = []

        Fiber.schedule { events << queue.pop(timeout: 0.01) }
        Fiber.schedule { events << :other_fiber }
        Fiber.set_scheduler(nil)

        assert_equal [:other_fiber, nil], events
        assert_operator scheduler.io_wait_calls, :>=, 1
      end

      def test_queue_wakes_native_and_scheduled_readiness_waiters
        return unless RUBY_ENGINE == "ruby"

        queue = Queue.new
        worker = Thread.new { queue.wait_pop }
        Timeout.timeout(5) { Thread.pass until queue.num_waiting == 1 }
        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        events = []

        Fiber.schedule { events << queue.wait_pop }
        Fiber.schedule { queue.push(:ready) }
        Fiber.set_scheduler(nil)

        assert_equal [true], events
        assert Timeout.timeout(5) { worker.value }
        assert_equal :ready, queue.pop
        assert_equal 0, queue.num_waiting
        assert_operator scheduler.io_wait_calls, :>=, 1
      ensure
        queue&.close
        worker&.kill
        worker&.join
      end

      def test_exchange_does_not_block_another_fiber
        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        exchanger = Exchanger.new
        events = []

        Fiber.schedule do
          events << :first_started
          events << exchanger.exchange(:first)
        end
        Fiber.schedule do
          events << exchanger.exchange(:second)
        end
        Fiber.set_scheduler(nil)

        assert_equal %i[first_started first second], events
        assert_operator scheduler.io_wait_calls, :>=, 1
      end

      def test_exchange_supports_nil_with_a_scheduler
        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        exchanger = Exchanger.new
        events = []

        Fiber.schedule do
          events << :first_started
          events << exchanger.exchange(:payload)
        end
        Fiber.schedule do
          events << exchanger.exchange(nil)
        end
        Fiber.set_scheduler(nil)

        assert_equal %i[first_started payload], events.first(2)
        assert_nil events.last
        assert_operator scheduler.io_wait_calls, :>=, 1
      end

      def test_exchange_timeout_does_not_block_another_fiber
        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        exchanger = Exchanger.new
        events = []

        Fiber.schedule do
          events << exchanger.exchange(:value, timeout: 0.01) { :fallback }
        end
        Fiber.schedule { events << :other_fiber }
        Fiber.set_scheduler(nil)

        assert_equal %i[other_fiber fallback], events
        assert_operator scheduler.io_wait_calls, :>=, 1
      end

      def test_exchange_uses_thread_scheduler_when_current_scheduler_is_unavailable
        return unless RUBY_ENGINE == "jruby"

        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        exchanger = Exchanger.new
        events = []
        current_scheduler = Fiber.method(:current_scheduler)
        Fiber.define_singleton_method(:current_scheduler) { nil }

        begin
          Fiber.schedule { events << exchanger.exchange(:value, timeout: 0.01) { :fallback } }
          Fiber.schedule { events << :other_fiber }
          Fiber.set_scheduler(nil)
        ensure
          Fiber.define_singleton_method(:current_scheduler, current_scheduler)
        end

        assert_equal %i[other_fiber fallback], events
        assert_operator scheduler.io_wait_calls, :>=, 1
      end

      def test_condition_variable_wait_does_not_block_another_fiber
        return unless RUBY_ENGINE == "ruby"

        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        mutex = Mutex.new
        condition = ConditionVariable.new
        events = []

        Fiber.schedule do
          mutex.synchronize do
            events << :waiting
            condition.wait(mutex)
            events << :resumed
          end
        end
        Fiber.schedule do
          events << :signaling
          mutex.synchronize { condition.signal }
        end
        Fiber.set_scheduler(nil)

        assert_equal %i[waiting signaling resumed], events
      end

      def test_thread_completion_wakes_scheduler_from_another_thread
        return unless RUBY_ENGINE == "ruby"

        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        scheduler_thread = Thread.current
        worker = Thread.new do
          Thread.pass until scheduler_thread.status == "sleep"
          :value
        end
        events = []

        Fiber.schedule do
          events << :waiting
          events << worker.value
        end
        Fiber.schedule { events << :other_fiber }
        Fiber.set_scheduler(nil)

        assert_equal %i[waiting other_fiber value], events
      ensure
        worker&.kill
        worker&.join
      end
    end
  end
end
