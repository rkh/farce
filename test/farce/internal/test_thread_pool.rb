# frozen_string_literal: true
require_relative "../../setup"

module Farce
  module Internal
    class TestThreadPool < Test
      def setup
        @pool = ThreadPool.new(max_threads: 2, capacity: 3)
        @threads = []
        @release = Thread::Queue.new
      end

      def teardown
        @release.close
        @threads.each(&:join)
        @pool.close
      end

      def caller_thread(&)
        @threads << Thread.new(&)
        @threads.last
      end

      def test_workers_are_lazy_reused_and_joined
        assert_equal 0, @pool.size
        worker = @pool.call { Thread.current }

        refute_same Thread.current, worker
        assert_same(worker, @pool.call { Thread.current })
        assert_equal 1, @pool.size
        @pool.close
        @pool.close

        refute_predicate worker, :alive?
        assert_predicate @pool, :closed?
        assert_raises(IOError) { @pool.call { :unused } }
      end

      def test_worker_errors_reach_caller_without_losing_worker
        worker = @pool.call { Thread.current }
        error = Class.new(Exception).new("job failed") # rubocop:disable Lint/InheritException -- verify non-StandardError delivery

        assert_same error, assert_raises(error.class) { @pool.call { raise error } }
        assert_same(worker, @pool.call { Thread.current })
        assert_equal(:recovered, @pool.call { :recovered })
      end

      def test_two_blocking_operations_run_concurrently
        started = Thread::Queue.new
        2.times do
          caller_thread do
            @pool.call do
              started << Thread.current
              @release.pop
            end
          end
        end
        workers = 2.times.map { started.pop }

        assert_equal 2, workers.uniq.size
        assert_equal 2, @pool.size
        2.times { @release << true }
        @threads.each(&:join)
        @pool.close

        assert workers.none?(&:alive?)
      end

      def test_invalid_bounds
        assert_raises(ArgumentError) { ThreadPool.new(max_threads: 0) }
        assert_raises(ArgumentError) { ThreadPool.new(max_threads: -1) }
        assert_raises(ArgumentError) { ThreadPool.new(max_threads: 2, capacity: 1) }
        assert_raises(ArgumentError) { @pool.call }
        assert_equal 0, @pool.size
      end

      def test_worker_cannot_close_its_own_pool
        assert_raises(ThreadError) { @pool.call { @pool.close } }
        refute_predicate @pool, :closed?
        assert_equal(:alive, @pool.call { :alive })
      end
    end
  end
end
