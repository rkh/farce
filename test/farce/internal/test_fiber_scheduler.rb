# frozen_string_literal: true

require_relative "../../setup"

module Farce
  class TestFiberScheduler < Test
    include Helpers::InternalTestHelpers

    Queue = Internal::Queue
    Exchanger = Internal::Exchanger

    def setup
      skip "Fiber schedulers are not supported" unless Fiber.respond_to?(:set_scheduler)
    end

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
  end
end
