# frozen_string_literal: true

require_relative "../../setup"

module Farce
  module Internal
    class TestSignal < Test
      include Helpers::InternalTestHelpers

      def teardown
        Fiber.set_scheduler(nil) if Fiber.respond_to?(:scheduler) && Fiber.scheduler
      end

      def test_initialization_and_generation
        signal = Signal.new

        assert_equal 0, signal.generation
        assert_equal 0, signal.num_waiting
        assert_predicate signal, :frozen?
        assert Ractor.shareable?(signal)
        assert_equal 1, signal.broadcast
        assert_equal 2, signal.broadcast
        assert_equal 2, signal.generation
      end

      def test_wait_returns_immediately_when_generation_already_changed
        signal = Signal.new
        observed = signal.generation
        signal.broadcast

        assert_equal 1, signal.wait(observed, timeout: 0)
      end

      def test_wait_without_a_generation_waits_for_the_next_broadcast
        signal = Signal.new
        signal.broadcast
        broadcaster = Thread.new do
          sleep 0.01
          signal.broadcast
        end

        assert_equal 2, signal.wait(timeout: 1)
        broadcaster.join
      end

      def test_timeout_and_fallback
        signal = Signal.new

        assert_nil signal.wait(timeout: 0)
        assert_equal :fallback, signal.wait(timeout: 0.01) { :fallback }
        assert_equal 0, signal.generation
        assert_equal 0, signal.num_waiting
      end

      def test_broadcast_wakes_all_waiters
        signal = Signal.new
        observed = signal.generation
        ready = Thread::Queue.new
        waiters = 8.times.map do
          Thread.new do
            ready << true
            signal.wait(observed, timeout: 1)
          end
        end
        8.times { ready.pop }
        Timeout.timeout(1) { Thread.pass until signal.num_waiting == waiters.size }

        assert_equal 8, signal.num_waiting
        assert_equal 1, signal.broadcast
        assert_equal [1], waiters.map(&:value).uniq
        assert_equal 0, signal.num_waiting
      end

      def test_generation_token_closes_the_check_to_wait_race
        signal = Signal.new
        observed = signal.generation

        signal.broadcast

        assert_equal 1, signal.wait(observed, timeout: 0)
        assert_nil signal.wait(timeout: 0)
      end

      def test_repeated_broadcasts
        signal = Signal.new
        observed = signal.generation

        100.times do |index|
          assert_equal index + 1, signal.broadcast
          observed = signal.wait(observed, timeout: 0)

          assert_equal index + 1, observed
        end
      end

      def test_concurrent_broadcasts_advance_generation_atomically
        signal = Signal.new
        broadcasters = 8.times.map do
          Thread.new { 100.times { signal.broadcast } }
        end
        broadcasters.each(&:join)

        assert_equal 800, signal.generation
      end

      def test_wait_from_multiple_ractors
        signal = Signal.new
        observed = signal.generation
        ready = Internal::Queue.new(capacity: nil)
        waiters = 4.times.map do
          Ractor.new(signal, ready, observed) do |shared, started, generation|
            started.push(true)
            shared.wait(generation, timeout: 1)
          end
        end
        4.times { ready.pop }

        signal.broadcast

        assert_equal [1], waiters.map { |waiter| ractor_value(waiter) }.uniq
      end

      def test_wait_does_not_block_a_fiber_scheduler
        return unless Fiber.respond_to?(:set_scheduler)

        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        signal = Signal.new
        observed = signal.generation
        events = []

        Fiber.schedule do
          events << :waiting
          events << signal.wait(observed)
        end
        Fiber.schedule do
          events << :broadcasting
          events << signal.num_waiting
          signal.broadcast
        end
        Fiber.set_scheduler(nil)

        assert_equal [:waiting, :broadcasting, 1, 1], events
        assert_operator scheduler.io_wait_calls, :>=, 1
      end

      def test_timeout_does_not_block_a_fiber_scheduler
        return unless Fiber.respond_to?(:set_scheduler)

        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        signal = Signal.new
        events = []

        Fiber.schedule { events << signal.wait(timeout: 0.01) }
        Fiber.schedule { events << :other_fiber }
        Fiber.set_scheduler(nil)

        assert_equal [:other_fiber, nil], events
        assert_operator scheduler.io_wait_calls, :>=, 1
      end

      def test_invalid_arguments
        signal = Signal.new

        assert_raises(TypeError) { signal.wait(:generation, timeout: 0) }
        assert_raises(ArgumentError) { signal.wait(timeout: -1) }
        assert_raises(ArgumentError) { signal.wait(timeout: Float::INFINITY) }
      end
    end
  end
end
