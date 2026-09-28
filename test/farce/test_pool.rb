# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestPool < Test
    unless RUBY_ENGINE == "truffleruby"
      class InsightScheduler < Helpers::Internal::FiberScheduler
        CHECKS = Counter.new

        def respond_to?(name, *)
          CHECKS.increment if name == :farce_runnable_count
          super
        end
      end
    end

    def test_custom_scheduler_resumes_dispatcher_after_starting_a_task
      return if RUBY_ENGINE == "truffleruby"
      require "helpers/queue_test_scheduler"
      pool = Pool.new(max_size: 1, shrink_after: nil) { Helpers::QueueTestScheduler.new }
      results = Queue.new
      pool.schedule(results) { |queue| queue << :first }
      pool.schedule(results) { |queue| queue << :second }

      assert_equal :first, results.pop(timeout: 2)
      assert_equal :second, results.pop(timeout: 2)
      close_pool(pool)

      assert_equal :closed, pool.state
      assert_nil pool.error
    ensure
      close_pool(pool)
    end

    def test_initialization_starts_the_minimum_size
      pool = Pool.new(min_size: 2, max_size: 3, shrink_after: nil)

      assert_equal :running, pool.state
      assert_equal 2, pool.size
      assert_nil pool.error
      refute_predicate pool, :closed?
      refute_predicate pool, :frozen?
      assert Ractor.shareable?(pool)
    ensure
      close_pool(pool)
    end

    def test_default_minimum_is_zero
      pool = Pool.new

      assert_equal 0, pool.min_size
      assert_equal 0, pool.size
      pool.close

      assert_equal :closed, pool.state
    ensure
      close_pool(pool)
    end

    def test_first_worker_starts_without_waiting_for_growth
      pool = Pool.new(grow_after: 60, shrink_after: nil)
      result = Queue.new

      pool.schedule(result, mode: :raise) { |queue| queue << :done }

      assert_equal :done, result.pop(timeout: 2)
      assert_equal 1, pool.size
    ensure
      close_pool(pool)
    end

    def test_idle_pool_retires_to_zero_and_restarts_immediately
      pool = Pool.new(grow_after: 60, shrink_after: 0.02)
      result = Queue.new

      pool.schedule(result, mode: :raise) { |queue| queue << :first }

      assert_equal :first, result.pop(timeout: 2)
      Timeout.timeout(2) { sleep 0.001 until pool.size.zero? } # rubocop:disable Style/ZeroLengthPredicate

      pool.schedule(result, mode: :raise) { |queue| queue << :second }

      assert_equal :second, result.pop(timeout: 2)
      assert_nil pool.error
    ensure
      close_pool(pool)
    end

    def test_schedule_dispatches_to_a_worker
      pool = Pool.new(max_size: 1, shrink_after: nil)
      result = Queue.new

      assert_same pool, pool.schedule(result, :done, mode: :raise) { |queue, value| queue << value }
      assert_equal :done, result.pop(timeout: 2)
    ensure
      close_pool(pool)
    end

    def test_queue_wait_grows_the_pool
      pool = Pool.new(max_size: 2, max_inflight: 1, grow_after: 0.01, shrink_after: nil)
      started = Queue.new
      result = Queue.new
      gate = Atom.new(false, mode: :raise)

      pool.schedule(started, gate, mode: :raise) do |queue, wait|
        queue << Ractor.current
        # Hold this worker's scheduler without competing for CPU with pool startup.
        Fiber.new(blocking: true) { wait.wait_until_changed(false) }.resume
      end
      first = started.pop(timeout: 2)

      refute_nil first, "the first pool worker did not start"

      pool.schedule(result, mode: :raise) { |queue| queue << Ractor.current }
      second = result.pop(timeout: 2)

      refute_nil second, lambda {
        "the second task did not run within 2 seconds " \
          "(pool state: #{pool.state}, workers: #{pool.size}, " \
          "queued tasks: #{pool.instance_variable_get(:@queue).size}, error: #{pool.error.inspect})"
      }
      refute_same first, second if Helpers::Internal.native_ractors?

      assert_nil pool.error
      assert_equal 2, pool.size
    ensure
      gate&.value = true
      close_pool(pool)
    end

    def test_inflight_limit_is_relaxed_at_maximum_size
      pool = Pool.new(max_size: 1, max_inflight: 1, shrink_after: nil)
      gate = Queue.new
      result = Queue.new

      pool.schedule(gate, mode: :raise, &:pop)
      pool.schedule(result, mode: :raise) { |queue| queue << :accepted }

      assert_equal :accepted, result.pop(timeout: 2)
      gate << nil
    ensure
      close_pool(pool)
    end

    def test_idle_extra_worker_retires
      pool = Pool.new(min_size: 1, max_size: 2, max_inflight: 1, grow_after: 0.005, shrink_after: 0.02)
      started = Queue.new
      gate = Atom.new(false, mode: :raise)
      extra_gate = Queue.new

      pool.schedule(started, gate, mode: :raise) do |queue, wait|
        queue << true
        Fiber.new(blocking: true) { wait.wait_until_changed(false) }.resume
      end
      started.pop(timeout: 2)
      # Keep the extra worker busy until its growth has been observed.
      pool.schedule(extra_gate, mode: :raise, &:pop)

      Timeout.timeout(2) { sleep 0.001 until pool.size == 2 }
      gate.value = true
      extra_gate << nil
      Timeout.timeout(2) { sleep 0.001 until pool.size == 1 }

      assert_equal 1, pool.size
    ensure
      gate&.value = true
      extra_gate&.close
      close_pool(pool)
    end

    def test_close_drains_work_and_rejects_submissions
      pool = Pool.new(max_size: 1, shrink_after: nil)
      result = Queue.new
      pool.schedule(result, mode: :raise) { |queue| queue << :done }

      assert_same pool, pool.close
      assert_raises(PoolClosedError) { pool.schedule { nil } }
      assert_equal :done, result.pop(timeout: 2)
      Timeout.timeout(2) { sleep 0.001 until pool.state == :closed }

      assert_equal 0, pool.size
    ensure
      close_pool(pool)
    end

    def test_close_rejects_a_submission_blocked_by_capacity
      # Hold admission below max_size so the queue stays full with thread-based tasks too.
      # Delay growth until after this test, since reaching max_size relaxes the inflight limit.
      pool = Pool.new(max_size: 2, max_inflight: 1, capacity: 1, grow_after: 60, shrink_after: nil)
      started = Queue.new
      gate = Atom.new(false, mode: :raise)
      pool.schedule(started, gate, mode: :raise) do |queue, wait|
        queue << true
        Fiber.new(blocking: true) { wait.wait_until_changed(false) }.resume
      end

      assert started.pop(timeout: 2)
      pool.schedule { nil }
      submitter = Thread.new do
        pool.schedule { nil }
      rescue PoolClosedError => e
        e
      end
      queue = pool.instance_variable_get(:@queue)
      Timeout.timeout(2) { Thread.pass until queue.num_waiting.positive? }
      pool.close

      assert submitter.join(2), "submission remained blocked after close"
      assert_instance_of PoolClosedError, submitter.value
    ensure
      gate&.value = true
      submitter&.kill&.join
      close_pool(pool)
    end

    def test_zero_minimum_still_drains_on_close
      pool = Pool.new(min_size: 0, max_size: 1, grow_after: 1, shrink_after: nil)
      result = Queue.new
      pool.schedule(result, mode: :raise) { |queue| queue << :done }

      pool.close

      assert_equal :done, result.pop(timeout: 2)
      Timeout.timeout(2) { sleep 0.001 until pool.state == :closed }

      assert_equal 0, pool.size
    ensure
      close_pool(pool)
    end

    def test_local_transfer_is_rejected
      pool = Pool.new(max_size: 1, shrink_after: nil)

      error = assert_raises(ArgumentError) { pool.schedule(mode: :local) { nil } }
      assert_equal "local transfer is not supported by a pool", error.message
    ensure
      close_pool(pool)
    end

    def test_invalid_sizes_are_rejected
      assert_raises(ArgumentError) { Pool.new(min_size: -1) }
      assert_raises(ArgumentError) { Pool.new(max_size: 0) }
      assert_raises(ArgumentError) { Pool.new(min_size: 2, max_size: 1) }
      assert_raises(ArgumentError) { Pool.new(max_inflight: 0) }
      assert_raises(ArgumentError) { Pool.new(grow_after: -1) }
    end

    def test_scheduler_insight_method_is_detected_once
      return if RUBY_ENGINE == "truffleruby"
      before = InsightScheduler::CHECKS.value
      pool = Pool.new(max_size: 1, shrink_after: nil) { InsightScheduler.new }
      result = Queue.new

      3.times { pool.schedule(result, mode: :raise) { |queue| queue << true } }

      3.times { assert result.pop(timeout: 2) }

      assert_equal before + 1, InsightScheduler::CHECKS.value
    ensure
      close_pool(pool)
    end

    private

    def close_pool(pool)
      return unless pool
      pool.close
      Timeout.timeout(2) { sleep 0.001 until pool.state == :closed }
    end
  end
end
