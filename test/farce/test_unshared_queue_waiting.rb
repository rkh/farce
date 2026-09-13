# frozen_string_literal: true

return unless RUBY_ENGINE == "ruby"

require_relative "../setup"

module Farce
  class TestUnsharedQueueWaiting < Test
    class SchedulerFailure < StandardError; end

    class RecordingScheduler < Helpers::QueueTestScheduler
      attr_reader :blockers, :unblock_threads, :io_waiters
      attr_accessor :fail_block, :fail_unblock, :spurious_block

      def initialize
        super
        @blockers = []
        @unblock_threads = []
        @io_waiters = []
      end

      def block(blocker, timeout = nil)
        @blockers << blocker
        if @fail_block
          @fail_block = false
          raise SchedulerFailure
        end
        if @spurious_block
          @spurious_block = false
          return false
        end
        super
      end

      def unblock(blocker, fiber)
        @unblock_threads << Thread.current
        super
        return unless @fail_unblock
        @fail_unblock = false
        raise SchedulerFailure
      end

      def io_wait(io, events, timeout)
        @io_waiters << io
        if @fail_block
          @fail_block = false
          raise SchedulerFailure
        end
        if @spurious_block
          @spurious_block = false
          return IO::READABLE
        end
        super
      end
    end

    # Resumes waiters inside unblock to exercise reentrant queue operations.
    class ImmediateScheduler
      def fiber(&)
        Fiber.new(blocking: false, &).tap(&:resume)
      end

      def block(_blocker, _timeout = nil) = Fiber.yield
      def unblock(_blocker, fiber) = fiber.resume
      def kernel_sleep(_duration = nil) = Fiber.yield
      def io_wait(*) = raise("unexpected IO wait")
      def fiber_interrupt(fiber, exception) = fiber.raise(exception)
      def close; end
    end

    def teardown
      Fiber.set_scheduler(nil) if Fiber.scheduler
    end

    def test_cross_thread_unblock_and_blocker_identity
      scheduler = RecordingScheduler.new
      Fiber.set_scheduler(scheduler)
      queue = new_queue
      result = nil
      Fiber.schedule { result = queue.pop }
      producer = Thread.new { queue.push(:ready) }
      producer.join
      Fiber.set_scheduler(nil)

      assert_equal :ready, result
      if io_path?
        assert_empty scheduler.unblock_threads
        assert_empty scheduler.blockers
        assert_equal 1, scheduler.io_wait_calls
      else
        assert_equal [producer], scheduler.unblock_threads
        assert_equal [queue.instance_variable_get(:@queue)], scheduler.blockers
        assert_equal 0, scheduler.io_wait_calls
      end

      assert_equal 0, queue.num_waiting
    end

    def test_timeouts_remove_fiber_waiters
      scheduler = RecordingScheduler.new
      Fiber.set_scheduler(scheduler)
      empty = new_queue
      full = new_queue(capacity: 1)
      full.push(:first)
      results = []
      Fiber.schedule { results << empty.pop(timeout: 0.002) { :expired } }
      Fiber.schedule { results << full.push(:second, timeout: 0.002) }
      Fiber.set_scheduler(nil)

      assert_equal [:expired, false], results
      assert_equal 0, empty.num_waiting
      assert_equal 0, full.num_waiting
      assert_equal(io_path? ? 2 : 0, scheduler.io_wait_calls)
    end

    def test_cancelled_fiber_is_removed_before_later_notifications
      scheduler = RecordingScheduler.new
      Fiber.set_scheduler(scheduler)
      queue = new_queue
      result = nil
      fiber = Fiber.schedule do
        queue.pop
      rescue SchedulerFailure
        result = :cancelled
      end
      fiber.raise(SchedulerFailure)

      assert_equal :cancelled, result
      assert_equal 0, queue.num_waiting
      assert queue.push(:next)
      assert_equal :next, queue.pop
      assert_empty scheduler.unblock_threads
    end

    def test_scheduler_block_failure_removes_waiter
      scheduler = RecordingScheduler.new
      scheduler.fail_block = true
      Fiber.set_scheduler(scheduler)
      queue = new_queue

      assert_raises(SchedulerFailure) { Fiber.schedule { queue.pop } }
      assert_equal 0, queue.num_waiting
      assert queue.push(:next)
      assert_equal :next, queue.pop
      assert_empty scheduler.unblock_threads
    end

    def test_unblock_failure_does_not_skip_other_waiters
      return if io_path?
      scheduler = RecordingScheduler.new
      scheduler.fail_unblock = true
      Fiber.set_scheduler(scheduler)
      queue = new_queue
      results = []
      2.times { Fiber.schedule { results << queue.wait_pop } }

      assert_raises(SchedulerFailure) { queue.push(:ready) }
      Fiber.set_scheduler(nil)

      assert_equal [true, true], results
      assert_equal 2, scheduler.unblock_calls
      assert_equal 0, queue.num_waiting
      assert_equal :ready, queue.pop
    end

    def test_spurious_scheduler_return_rechecks_queue_condition
      scheduler = RecordingScheduler.new
      scheduler.spurious_block = true
      Fiber.set_scheduler(scheduler)
      queue = new_queue
      result = nil
      Fiber.schedule { result = queue.pop }

      assert_nil result
      assert_equal 1, queue.num_waiting
      queue.push(:ready)
      Fiber.set_scheduler(nil)

      assert_equal :ready, result
      assert_equal 2, (io_path? ? scheduler.io_waiters : scheduler.blockers).size
    end

    def test_reentrant_unblock_does_not_wake_a_new_wait_registration
      return if io_path?
      Fiber.set_scheduler(ImmediateScheduler.new)
      queue = new_queue
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

    def test_close_wakes_every_waiting_fiber
      scheduler = RecordingScheduler.new
      Fiber.set_scheduler(scheduler)
      queue = new_queue
      results = []
      3.times do
        Fiber.schedule do
          queue.pop
        rescue ClosedQueueError
          results << :closed
        end
      end
      queue.close
      Fiber.set_scheduler(nil)

      assert_equal [:closed] * 3, results
      assert_equal 0, queue.num_waiting
      assert_equal(io_path? ? 3 : 0, scheduler.io_wait_calls)
    end

    def test_blocking_fiber_uses_thread_waiting_even_with_scheduler
      scheduler = RecordingScheduler.new
      Fiber.set_scheduler(scheduler)
      queue = new_queue
      producer = Thread.new do
        Timeout.timeout(2) { Thread.pass until queue.num_waiting == 1 }
        queue.push(:ready)
      end
      result = Fiber.new(blocking: true) { queue.pop(timeout: 2) }.resume
      producer.value

      assert_equal :ready, result
      assert_empty scheduler.blockers
      assert_empty scheduler.unblock_threads
      assert_equal 0, scheduler.io_wait_calls
    ensure
      producer&.kill
    end

    def test_thread_cancellation_and_spurious_wakeup_leave_queue_usable
      queue = new_queue
      consumer = Thread.new { queue.pop }
      Timeout.timeout(2) { Thread.pass until queue.num_waiting == 1 }
      consumer.wakeup
      Thread.pass
      consumer.kill.join

      assert_equal 0, queue.num_waiting
      assert queue.push(:ready)
      assert_equal :ready, queue.pop
    ensure
      consumer&.kill
    end

    def test_thread_and_fiber_waiters_share_the_same_readiness_transition
      scheduler = RecordingScheduler.new
      Fiber.set_scheduler(scheduler)
      queue = new_queue
      fiber_result = nil
      thread = Thread.new { queue.wait_pop(timeout: 2) }
      Fiber.schedule { fiber_result = queue.wait_pop(timeout: 2) }
      Timeout.timeout(2) { Thread.pass until queue.num_waiting == 2 }
      queue.push(:ready)
      thread.join
      Fiber.set_scheduler(nil)

      assert thread.value
      assert fiber_result
      assert_equal 0, queue.num_waiting
      assert_equal :ready, queue.pop
    ensure
      thread&.kill
    end

    def test_waiting_fibers_survive_gc_compaction
      scheduler = RecordingScheduler.new
      Fiber.set_scheduler(scheduler)
      queue = new_queue
      results = []
      10.times { Fiber.schedule { results << queue.pop } }
      GC.verify_compaction_references(double_heap: true, toward: :empty)
      10.times { |i| queue.push([i]) }
      Fiber.set_scheduler(nil)

      assert_equal (0...10).map { [it] }, results
      assert_equal 0, queue.num_waiting
    end

    private def fiber_wait = :auto
    private def new_queue(**) = Unshared::Queue.new(fiber_wait:, **)
    private def io_path? = fiber_wait == :auto ? Internal::UNSHARED_FIBER_IO : fiber_wait == :io
  end

  class TestUnsharedQueueIOWaiting < TestUnsharedQueueWaiting
    def setup
      skip "IO-based fiber waiting is unavailable on Windows" if Gem.win_platform?
    end

    private def fiber_wait = :io
  end

  class TestUnsharedQueueBlockWaiting < TestUnsharedQueueWaiting
    private def fiber_wait = :block
  end
end
