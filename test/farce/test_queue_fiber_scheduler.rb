# frozen_string_literal: true

return unless RUBY_ENGINE == "ruby"

require_relative "../setup"

module Farce
  class TestQueueFiberScheduler < Test
    def setup
      skip "Fiber schedulers are not supported" unless Fiber.respond_to?(:set_scheduler)
    end

    def teardown
      Fiber.set_scheduler(nil) if Fiber.respond_to?(:scheduler) && Fiber.scheduler
    end

    def test_blocked_pop_parks_only_the_current_fiber
      scheduler = Helpers::QueueTestScheduler.new
      Fiber.set_scheduler(scheduler)
      queue = queue_class.new
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

    def test_blocked_push_parks_only_the_current_fiber
      scheduler = Helpers::QueueTestScheduler.new
      Fiber.set_scheduler(scheduler)
      queue = queue_class.new(capacity: 1)
      queue.push(:first)
      events = []

      Fiber.schedule do
        events << :push_started
        events << queue.push(:second)
      end
      Fiber.schedule { events << queue.pop }
      Fiber.set_scheduler(nil)

      assert_equal [:push_started, :first, true], events
      assert_equal :second, queue.pop
      assert_operator scheduler.io_wait_calls, :>=, 1
    end

    private def queue_class = Queue
  end

  class TestStrictQueueFiberScheduler < TestQueueFiberScheduler
    private def queue_class = StrictQueue
  end
end
