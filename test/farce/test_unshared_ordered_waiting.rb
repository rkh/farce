# frozen_string_literal: true

return unless RUBY_ENGINE == "ruby"

require_relative "../setup"

module Farce
  class TestUnsharedOrderedWaiting < Test
    class SchedulerFailure < StandardError; end

    class Scheduler < Helpers::QueueTestScheduler
      attr_accessor :fail_unblock, :spurious_block
      attr_reader :wait_ios

      def initialize
        super
        @wait_ios = []
      end

      def io_wait(io, ...)
        @wait_ios << io
        if @spurious_block
          @spurious_block = false
          return IO::READABLE
        end
        super
      end

      def block(...)
        if @spurious_block
          @spurious_block = false
          return false
        end
        super
      end

      def unblock(...)
        super
        return unless @fail_unblock
        @fail_unblock = false
        raise SchedulerFailure
      end
    end

    class ImmediateScheduler
      def fiber(&) = Fiber.new(blocking: false, &).tap(&:resume)
      def block(*) = Fiber.yield
      def unblock(_blocker, fiber) = fiber.resume
      def kernel_sleep(*) = Fiber.yield
      def io_wait(*) = raise("unexpected IO wait")
      def fiber_interrupt(fiber, exception) = fiber.raise(exception)
      def close; end
    end

    def teardown
      Fiber.set_scheduler(nil) if Fiber.scheduler
    end

    def test_modes_coexist_on_one_scheduler
      scheduler = Scheduler.new
      Fiber.set_scheduler(scheduler)
      queues = [Unshared::Queue, Unshared::PriorityQueue, Unshared::TimerQueue].flat_map do |klass|
        %i[io block].map { |fiber_wait| klass.new(fiber_wait:) }
      end
      results = []
      queues.each_with_index do |queue, index|
        Fiber.schedule { results << [index, queue.pop(timeout: 2)] }
      end
      producer = Thread.new { queues.each_with_index { |queue, index| queue.push(index) } }
      producer.join
      Fiber.set_scheduler(nil)

      assert_equal (0...6).map { [it, it] }, results.sort
      assert_equal 3, scheduler.io_wait_calls
      assert_equal 3, scheduler.block_calls
      assert_equal 3, scheduler.unblock_calls
      queues.each { |queue| assert_equal 0, queue.num_waiting }
    ensure
      producer&.kill
    end

    def test_generation_advances_on_the_native_fast_path
      [Unshared::PriorityQueue, Unshared::TimerQueue].each do |klass|
        queue = new_queue(klass, capacity: 1)
        signal = queue.instance_variable_get(:@signal)

        assert_instance_of Internal::UnsharedSignal.for(fiber_wait).class, signal
        observed = signal.generation

        assert queue.try_push(:ready)
        assert_equal observed + 1, signal.wait(observed, timeout: 0)
        refute queue.try_push(:full)
        assert_equal :ready, queue.peek
        assert_equal observed + 1, signal.generation
        assert_equal :ready, queue.try_pop
        assert_equal observed + 2, signal.generation
        assert_nil queue.try_pop
        assert_equal observed + 2, signal.generation
      end
    end

    def test_cross_thread_notifications_and_capacity_waits
      [Unshared::PriorityQueue, Unshared::TimerQueue].each do |klass|
        scheduler = Scheduler.new
        Fiber.set_scheduler(scheduler)
        queue = new_queue(klass, capacity: 1)
        results = []
        Fiber.schedule { results << queue.pop(timeout: 2) }
        producer = Thread.new { queue.push(:first) }
        producer.join
        Fiber.schedule { results << queue.push(:second, timeout: 2) }
        Fiber.set_scheduler(nil)

        assert_equal [:first, true], results
        assert_equal :second, queue.pop
        assert_wait_protocol(scheduler)
        assert_operator(io_path? ? scheduler.io_wait_calls : scheduler.unblock_calls, :>=, 2)
        assert_equal 0, queue.num_waiting
      ensure
        producer&.kill
      end
    end

    def test_threads_and_fibers_wait_on_the_same_signal
      [Unshared::PriorityQueue, Unshared::TimerQueue].each do |klass|
        scheduler = Scheduler.new
        Fiber.set_scheduler(scheduler)
        queue = new_queue(klass)
        result = nil
        Fiber.schedule { result = queue.wait_pop(timeout: 2) }
        waiter = Thread.new { queue.wait_pop(timeout: 2) }
        Timeout.timeout(2) { Thread.pass until queue.num_waiting == 2 }
        queue.push(:ready)

        assert waiter.join(2)
        Fiber.set_scheduler(nil)

        assert result
        assert waiter.value
        assert_equal 0, queue.num_waiting
        assert_equal :ready, queue.pop
        assert_wait_protocol(scheduler)
      ensure
        waiter&.kill
      end
    end

    def test_timeouts_cancellation_and_spurious_returns
      [Unshared::PriorityQueue, Unshared::TimerQueue].each do |klass|
        scheduler = Scheduler.new
        scheduler.spurious_block = true
        Fiber.set_scheduler(scheduler)
        queue = new_queue(klass)
        result = nil
        fiber = Fiber.schedule do
          queue.pop
        rescue SchedulerFailure
          result = :cancelled
        end
        fiber.raise(SchedulerFailure)

        assert_equal :cancelled, result
        assert_equal 0, queue.num_waiting
        Fiber.schedule { result = queue.pop(timeout: 0.001) { :expired } }
        Fiber.set_scheduler(nil)

        assert_equal :expired, result
        assert_equal 0, queue.num_waiting
        assert_wait_protocol(scheduler)
        assert queue.push(:ready)
        assert_equal :ready, queue.pop
      end
    end

    def test_scheduler_notification_failure_releases_the_callback_lock
      return if io_path?
      [Unshared::PriorityQueue, Unshared::TimerQueue].each do |klass|
        scheduler = Scheduler.new
        Fiber.set_scheduler(scheduler)
        queue = new_queue(klass)
        results = []
        2.times { Fiber.schedule { results << queue.pop(timeout: 2) } }
        scheduler.fail_unblock = true
        assert_raises(SchedulerFailure) { queue.push(:cancelled) }
        assert_predicate queue, :empty?
        queue.push(:first)
        queue.push(:second)
        Fiber.set_scheduler(nil)

        assert_equal %i[first second], results
        assert_equal 2, scheduler.unblock_calls
        assert_equal 0, queue.num_waiting
        assert_wait_protocol(scheduler)
      end
    end

    def test_synchronous_unblock_can_wait_for_commit_and_register_again
      return if io_path?
      Fiber.set_scheduler(ImmediateScheduler.new)
      [Unshared::PriorityQueue, Unshared::TimerQueue].each do |klass|
        queue = new_queue(klass)
        results = []
        fiber = Fiber.schedule { 3.times { results << queue.pop } }
        3.times do |i|
          assert_equal 1, queue.num_waiting
          queue.push(i)

          assert_equal (0..i).to_a, results
        end
        refute_predicate fiber, :alive?
        assert_equal 0, queue.num_waiting
      end
    end

    def test_waiters_survive_compaction_and_close
      [Unshared::PriorityQueue, Unshared::TimerQueue].each do |klass|
        scheduler = Scheduler.new
        Fiber.set_scheduler(scheduler)
        queue = new_queue(klass)
        results = []
        6.times do
          Fiber.schedule do
            queue.pop
          rescue ClosedQueueError
            results << :closed
          end
        end
        GC.verify_compaction_references(double_heap: true, toward: :empty)
        queue.close
        Fiber.set_scheduler(nil)

        assert_equal [:closed] * 6, results
        assert_equal 0, queue.num_waiting
        assert_wait_protocol(scheduler)
      end
    end

    def test_earlier_timer_interrupts_a_future_deadline
      scheduler = Scheduler.new
      Fiber.set_scheduler(scheduler)
      queue = new_queue(Unshared::TimerQueue)
      queue.push(:later, delay: 60)
      result = nil
      Fiber.schedule { result = queue.pop(timeout: 2) }
      Fiber.schedule { queue.push(:ready, at: -1.0) }
      Fiber.set_scheduler(nil)

      assert_equal :ready, result
      assert_equal :later, queue.peek
      assert_equal 0, queue.num_waiting
      assert_wait_protocol(scheduler)
    end

    private

    def fiber_wait = :auto
    def new_queue(klass, **) = klass.new(fiber_wait:, **)
    def io_path? = fiber_wait == :auto ? Internal::UNSHARED_FIBER_IO : fiber_wait == :io

    def assert_wait_protocol(scheduler)
      if io_path?
        assert_operator scheduler.io_wait_calls, :>=, 1
      else
        assert_equal 0, scheduler.io_wait_calls
        assert_operator scheduler.block_calls, :>=, 1
      end
    end
  end

  class TestUnsharedOrderedIOWaiting < TestUnsharedOrderedWaiting
    def setup
      skip "IO-based fiber waiting is unavailable on Windows" if Gem.win_platform?
    end

    private def fiber_wait = :io
  end

  class TestUnsharedOrderedBlockWaiting < TestUnsharedOrderedWaiting
    private def fiber_wait = :block
  end
end
