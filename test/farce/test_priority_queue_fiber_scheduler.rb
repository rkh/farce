# frozen_string_literal: true

return unless RUBY_ENGINE == "ruby" && Fiber.respond_to?(:set_scheduler)

require_relative "../setup"

module Farce
  class TestPriorityQueueFiberScheduler < Test
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
        queue.push(:value, priority: 1)
      end
      Fiber.set_scheduler(nil)

      assert_equal %i[pop_started producer_ran value], events
      assert_wait_protocol(scheduler)
    end

    def test_blocked_push_parks_only_the_current_fiber
      scheduler = Helpers::QueueTestScheduler.new
      Fiber.set_scheduler(scheduler)
      queue = queue_class.new(capacity: 1)
      queue.push(:first, priority: 2)
      events = []

      Fiber.schedule do
        events << :push_started
        events << queue.push(:second, priority: 1)
      end
      Fiber.schedule { events << queue.pop }
      Fiber.set_scheduler(nil)

      assert_equal [:push_started, :first, true], events
      assert_equal :second, queue.pop
      assert_wait_protocol(scheduler)
    end

    def test_timeout_does_not_block_another_fiber
      scheduler = Helpers::QueueTestScheduler.new
      Fiber.set_scheduler(scheduler)
      queue = queue_class.new
      events = []

      Fiber.schedule { events << queue.pop(timeout: 0.01) }
      Fiber.schedule { events << :other_fiber }
      Fiber.set_scheduler(nil)

      assert_equal [:other_fiber, nil], events
      assert_wait_protocol(scheduler)
    end
    private def assert_wait_protocol(scheduler)
      if queue_class == Unshared::PriorityQueue && !Internal::UNSHARED_FIBER_IO
        assert_equal 0, scheduler.io_wait_calls
        assert_operator scheduler.block_calls, :>=, 1
      else
        assert_operator scheduler.io_wait_calls, :>=, 1
      end
    end

    private def queue_class = PriorityQueue
  end

  class TestStrictPriorityQueueFiberScheduler < TestPriorityQueueFiberScheduler
    private def queue_class = Strict::PriorityQueue
  end

  class TestUnsharedPriorityQueueFiberScheduler < TestPriorityQueueFiberScheduler
    private def queue_class = Unshared::PriorityQueue
  end
end
