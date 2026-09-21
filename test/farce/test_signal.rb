# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "internal/test_signal"

module Farce
  class TestSignal < Internal::TestSignal
    def test_public_shareability
      signal = Signal.new

      assert_predicate signal, :ractor_shareable?
      assert Ractor.shareable?(signal)
    end

    def test_wait_until_checks_immediately_and_returns_the_result
      signal = Signal.new
      resource = Object.new

      assert_same resource, signal.wait_until(timeout: 0) { resource }
      assert_equal 0, signal.num_waiting
    end

    def test_wait_until_zero_timeout_checks_once
      signal = Signal.new
      calls = 0

      result = signal.wait_until(timeout: 0) do
        calls += 1
        false
      end

      assert_nil result
      assert_equal 1, calls
    end

    def test_wait_until_does_not_miss_a_broadcast_during_the_check
      signal = Signal.new
      calls = 0
      result = signal.wait_until(timeout: 1) do
        calls += 1
        next :ready if calls == 2
        signal.broadcast
        false
      end

      assert_equal :ready, result
      assert_equal 2, calls
    end

    def test_wait_until_rechecks_after_broadcasts
      signal = Signal.new
      resources = Strict::Queue.new
      checks = Thread::Queue.new
      waiter = Thread.new do
        signal.wait_until do
          checks << true
          resources.try_pop
        end
      end
      Timeout.timeout(2) do
        checks.pop
        signal.broadcast
        checks.pop
        resources.push(:resource)
        signal.broadcast

        assert_equal :resource, waiter.value
      end
      assert_equal 0, signal.num_waiting
    ensure
      waiter&.kill&.join
    end

    def test_wait_until_timeout_includes_checks_and_does_not_reset_after_broadcasts
      signal = Signal.new
      calls = 0
      result = Timeout.timeout(2) do
        signal.wait_until(timeout: 0.05) do
          calls += 1
          sleep 0.02
          signal.broadcast
          false
        end
      end

      assert_nil result
      assert_operator calls, :<=, 3
      assert_equal 0, signal.num_waiting
    end

    def test_wait_until_times_out_without_broadcasts
      signal = Signal.new
      calls = 0
      result = signal.wait_until(timeout: 0.01) do
        calls += 1
        nil
      end

      assert_nil result
      assert_equal 1, calls
      assert_equal 0, signal.num_waiting
    end

    def test_wait_until_propagates_exceptions_and_can_be_reused
      signal = Signal.new

      assert_raises(RuntimeError) { signal.wait_until { raise "failed check" } }
      assert_equal(:ready, signal.wait_until { :ready })
      assert_equal 0, signal.num_waiting
    end

    def test_wait_until_validates_arguments_before_checking
      signal = Signal.new

      assert_raises(LocalJumpError) { signal.wait_until(timeout: 0) }
      [-1, Float::INFINITY, Float::NAN].each do |timeout|
        assert_raises(ArgumentError) { signal.wait_until(timeout:) { flunk "invalid timeout accepted" } }
      end
    end

    def test_wait_until_across_ractors
      signal = Signal.new
      resources = Strict::Queue.new
      worker = Ractor.new(signal, resources) do |shared, queue|
        shared.wait_until(timeout: 2) { queue.try_pop }
      end
      resources.push(:resource)
      signal.broadcast

      assert_equal :resource, ractor_value(worker)
    end

    def test_wait_until_with_scheduled_fibers
      return unless Fiber.respond_to?(:set_scheduler)

      scheduler = Helpers::QueueTestScheduler.new
      Fiber.set_scheduler(scheduler)
      signal = Signal.new
      resource = nil
      received = []
      Fiber.schedule { received << signal.wait_until(timeout: 1) { resource } }
      Fiber.schedule do
        resource = :ready
        signal.broadcast
      end
      Fiber.set_scheduler(nil)

      assert_equal [:ready], received
      assert_operator scheduler.io_wait_calls, :>=, 1
    end

    private

    def signal_class = Farce::Signal
    def shareable_signal? = true

    def assert_wait_protocol(scheduler)
      assert_operator scheduler.io_wait_calls, :>=, 1
    end
  end
end
