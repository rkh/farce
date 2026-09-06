# frozen_string_literal: true
return unless RUBY_ENGINE == "ruby"
require_relative "../../setup"

module Farce
  module Internal
    class TestThreadPoolFiberScheduler < Test
      def setup
        @scheduler = FiberScheduler.new(backend: ENV.fetch("BACKEND", "auto").to_sym)
        Fiber.set_scheduler(@scheduler)
        @pool = ThreadPool.new(max_threads: 1, capacity: 1)
        @release = Thread::Queue.new
        @closed_notice = Thread::Queue.new
      end

      def teardown
        @release.close
        Fiber.set_scheduler(nil)
        @pool.close
      end

      def test_default_pool_survives_scheduler_close_and_replacement
        pool = ThreadPool.current
        used_pool = nil
        Fiber.schedule { used_pool = @scheduler.send(:background) { ThreadPool.current } }
        @scheduler.run
        Fiber.set_scheduler(nil)

        refute_predicate pool, :closed?
        assert_same pool, used_pool
        assert_equal(:usable, pool.call { :usable })
        @scheduler = FiberScheduler.new(backend: ENV.fetch("BACKEND", "auto").to_sym)
        Fiber.set_scheduler(@scheduler)
        used_pool = nil
        Fiber.schedule { used_pool = @scheduler.send(:background) { ThreadPool.current } }
        @scheduler.run

        assert_same pool, used_pool
      end

      def test_injected_pool_is_used_and_remains_open
        Fiber.set_scheduler(nil)
        @scheduler = FiberScheduler.new(backend: ENV.fetch("BACKEND", "auto").to_sym, thread_pool: @pool)
        Fiber.set_scheduler(@scheduler)
        expected = @pool.call { Thread.current }
        actual = nil
        Fiber.schedule { actual = @scheduler.send(:background) { Thread.current } }
        @scheduler.run
        Fiber.set_scheduler(nil)

        assert_same expected, actual
        refute_predicate @pool, :closed?
        assert_equal(:usable, @pool.call { :usable })
      end

      def test_scheduler_close_does_not_wait_for_another_pool_user
        Fiber.set_scheduler(nil)
        @scheduler = FiberScheduler.new(backend: ENV.fetch("BACKEND", "auto").to_sym, thread_pool: @pool)
        Fiber.set_scheduler(@scheduler)
        started = Thread::Queue.new
        caller = Thread.new do
          @pool.call do
            started << true
            @release.pop
          end
        end
        started.pop
        closer = Thread.new do
          Timeout.timeout(2) { @closed_notice.pop }
        rescue Timeout::Error
          @timed_out = true
        ensure
          @release << true
        end
        @scheduler.close
        @closed_notice << true
        caller.join
        closer.join

        refute @timed_out
        refute_predicate @pool, :closed?
      ensure
        @release << true
        caller&.join
        closer&.join
      end

      def occupy_worker
        started = Thread::Queue.new
        Fiber.schedule do
          @pool.call do
            started << true
            @release.pop
          end
        end
        started.pop
      end

      def test_capacity_wait_yields_and_cancellation_preserves_capacity
        occupy_worker
        executed = cancelled = progressed = false
        waiter = Fiber.schedule do
          @pool.call { executed = true }
        rescue Timeout::Error
          cancelled = true
        end
        Fiber.schedule { progressed = true }

        assert progressed
        refute executed
        assert_equal 1, @pool.size
        @scheduler.fiber_interrupt(waiter, Timeout::Error.new)
        Fiber.schedule { @release << true }
        @scheduler.run

        assert cancelled
        refute executed
        value = nil
        Fiber.schedule { value = @pool.call { :reused } }
        @scheduler.run

        assert_equal :reused, value
      end

      def test_queued_cancellation_skips_job_without_waiting_for_busy_worker
        @pool.close
        @pool = ThreadPool.new(max_threads: 1, capacity: 2)
        occupy_worker
        executed = cancelled = false
        waiter = Fiber.schedule do
          @pool.call { executed = true }
        rescue Timeout::Error
          cancelled = true
          @release << true
        end
        @scheduler.fiber_interrupt(waiter, Timeout::Error.new)
        @scheduler.run

        assert cancelled
        refute executed
      end

      def test_running_cancellation_waits_before_caller_cleanup
        started = Thread::Queue.new
        finished = cleaned = false
        waiter = Fiber.schedule do
          @pool.call do
            started << true
            @release.pop
            finished = true
          end
        rescue Timeout::Error
          assert finished
        ensure
          cleaned = true
        end
        started.pop
        @scheduler.fiber_interrupt(waiter, Timeout::Error.new)
        releaser = Thread.new do
          sleep 0.02
          @release << true
        end
        @scheduler.run

        assert cleaned
        assert finished
      ensure
        releaser&.join
      end

      def test_close_drains_jobs_and_wakes_capacity_waiters
        occupy_worker
        rejected = executed = false
        Fiber.schedule do
          @pool.call { executed = true }
        rescue IOError
          rejected = true
        end
        closer = Thread.new { @pool.close }
        Thread.pass until @pool.closed?
        @release << true
        @scheduler.run
        closer.join

        assert rejected
        refute executed
        assert_predicate @pool, :closed?
      ensure
        @release.close
        closer&.join
      end
    end
  end
end
