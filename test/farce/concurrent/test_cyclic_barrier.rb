# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../../setup"

module Farce
  module Concurrent
    class TestCyclicBarrier < Test
      include Helpers::InternalTestHelpers

      def test_initial_state_and_shareability
        barrier = CyclicBarrier.new(3)

        assert_equal 3, barrier.parties
        assert_equal 0, barrier.number_waiting
        refute_predicate barrier, :broken?
        refute_predicate barrier, :frozen?
        assert_predicate barrier, :ractor_shareable?
        assert Ractor.shareable?(barrier)
      end

      def test_parties_must_be_a_positive_integer
        [0, -1, 1.5, "2", nil, Object.new].each do |parties|
          assert_raises(ArgumentError) { CyclicBarrier.new(parties) }
        end
      end

      def test_single_party_barrier_is_reusable
        calls = Counter.new
        barrier = CyclicBarrier.new(1) { calls.increment }

        5.times do |index|
          assert barrier.wait(0)
          assert_equal index + 1, calls.value
          assert_equal 0, barrier.number_waiting
          refute_predicate barrier, :broken?
        end
      end

      def test_threads_wait_for_each_other_across_generations
        calls = Counter.new
        barrier = CyclicBarrier.new(4) { calls.increment }
        workers = 4.times.map do
          Thread.new do
            20.times.map do |index|
              [barrier.wait(5), calls.value >= index + 1]
            end
          end
        end

        assert_equal [[[true, true]] * 20] * 4, workers.map(&:value)
        assert_equal 20, calls.value
        assert_equal 0, barrier.number_waiting
        refute_predicate barrier, :broken?
      ensure
        workers&.each { it.kill if it.alive? }
        workers&.each(&:join)
      end

      def test_action_runs_in_the_last_arriving_thread
        caller_id = Strict::Atom.new
        barrier = CyclicBarrier.new(2) { caller_id.value = Thread.current.object_id }
        worker = Thread.new { barrier.wait(5) }
        wait_for_waiters(barrier, 1)

        assert barrier.wait(5)
        assert worker.value
        assert_equal Thread.current.object_id, caller_id.value
      ensure
        worker&.kill if worker&.alive?
        worker&.join
      end

      def test_action_finishes_before_waiters_are_released
        entered = Flag.new
        release = Flag.new
        barrier = CyclicBarrier.new(3) do
          entered.set
          release.wait_until_set(timeout: 5)
        end
        results = Strict::Queue.new
        workers = 3.times.map { Thread.new { results << barrier.wait(5) } }

        assert entered.wait_until_set(timeout: 5)
        assert_empty results
        release.set
        workers.each(&:value)

        received = ::Array.new(3) { results.pop }

        assert_equal [true] * 3, received
      ensure
        release&.set
        workers&.each { it.kill if it.alive? }
        workers&.each(&:join)
      end

      def test_timeout_breaks_the_barrier_until_reset
        calls = Counter.new
        barrier = CyclicBarrier.new(2) { calls.increment }

        refute barrier.wait(0)
        assert_predicate barrier, :broken?
        assert_equal 0, barrier.number_waiting
        4.times { refute barrier.wait(0) }

        assert_equal 0, calls.value
        assert_equal 0, barrier.number_waiting
        assert_predicate barrier, :broken?
        assert_nil barrier.reset
        refute_predicate barrier, :broken?
      end

      def test_invalid_timeouts_do_not_register_a_waiter
        barrier = CyclicBarrier.new(2)

        [-1, Float::INFINITY, Float::NAN].each do |timeout|
          assert_raises(ArgumentError) { barrier.wait(timeout) }
          assert_equal 0, barrier.number_waiting
          refute_predicate barrier, :broken?
        end
      end

      def test_timeout_releases_other_waiters
        barrier = CyclicBarrier.new(3)
        worker = Thread.new { barrier.wait(5) }
        wait_for_waiters(barrier, 1)

        refute barrier.wait(0.01)
        refute worker.value
        assert_predicate barrier, :broken?
        assert_equal 0, barrier.number_waiting
      ensure
        worker&.kill if worker&.alive?
        worker&.join
      end

      def test_reset_releases_waiters_and_starts_a_new_generation
        barrier = CyclicBarrier.new(3)
        workers = 2.times.map { Thread.new { barrier.wait(5) } }
        wait_for_waiters(barrier, 2)

        assert_nil barrier.reset
        assert_equal [false, false], workers.map(&:value)
        assert_equal 0, barrier.number_waiting
        refute_predicate barrier, :broken?
        workers = 2.times.map { Thread.new { barrier.wait(5) } }

        assert barrier.wait(5)
        assert_equal [true, true], workers.map(&:value)
      ensure
        workers&.each { it.kill if it.alive? }
        workers&.each(&:join)
      end

      def test_action_exception_breaks_the_generation_and_releases_waiters
        calls = Counter.new
        barrier = CyclicBarrier.new(2) { raise "action failed" if calls.increment.value == 1 }
        worker = Thread.new { barrier.wait(5) }
        wait_for_waiters(barrier, 1)

        error = assert_raises(RuntimeError) { barrier.wait(5) }

        assert_equal "action failed", error.message
        assert worker.join(1), "action failure did not release the other waiter"
        refute worker.value
        assert_predicate barrier, :broken?
        assert_equal 0, barrier.number_waiting
        barrier.reset
        worker = Thread.new { barrier.wait(5) }

        assert barrier.wait(5)
        assert worker.value
      ensure
        worker&.kill if worker&.alive?
        worker&.join
      end

      def test_wait_across_ractors_and_generations
        calls = Counter.new
        barrier = CyclicBarrier.new(3) { calls.increment }
        workers = 2.times.map do
          Ractor.new(barrier) { |shared| 3.times.map { shared.wait(5) } }
        end
        results = 3.times.map { barrier.wait(5) }

        assert_equal [true] * 3, results
        worker_results = workers.map { ractor_value(it) }

        assert_equal [[true] * 3] * 2, worker_results
        assert_equal 3, calls.value
      end

      def test_wait_cooperates_with_a_fiber_scheduler
        return unless Fiber.respond_to?(:set_scheduler)

        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        barrier = CyclicBarrier.new(3)
        results = []
        2.times { Fiber.schedule { results << barrier.wait(5) } }

        assert_equal 2, barrier.number_waiting
        assert_empty results
        Fiber.schedule { results << barrier.wait(5) }
        Fiber.set_scheduler(nil)

        assert_equal [true] * 3, results
        assert_equal 0, barrier.number_waiting
        refute_predicate barrier, :broken?
      ensure
        Fiber.set_scheduler(nil) if Fiber.respond_to?(:set_scheduler)
      end

      def test_freezing_prevents_wait_and_reset
        barrier = CyclicBarrier.new(1)
        barrier.freeze

        assert_predicate barrier, :frozen?
        assert_raises(FrozenError) { barrier.wait(0) }
        assert_raises(FrozenError) { barrier.reset }
        assert_equal 0, barrier.number_waiting
      end

      def test_live_state_cannot_be_copied_or_marshaled
        barrier = CyclicBarrier.new(2)

        assert_raises(TypeError) { barrier.dup }
        assert_raises(TypeError) { barrier.clone }
        assert_raises(TypeError) { Marshal.dump(barrier) }
      end

      private

      def wait_for_waiters(barrier, count)
        Timeout.timeout(5) { Thread.pass until barrier.number_waiting == count }
      end
    end
  end
end
