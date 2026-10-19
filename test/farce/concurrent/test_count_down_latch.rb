# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../../setup"

module Farce
  module Concurrent
    class TestCountDownLatch < Test
      include Helpers::InternalTestHelpers

      def test_initial_count_and_shareability
        latch = CountDownLatch.new

        assert_equal 1, latch.count
        assert_predicate latch, :ractor_shareable?
        assert Ractor.shareable?(latch)
        refute_predicate latch, :frozen?
      end

      def test_zero_count_is_already_open
        latch = CountDownLatch.new(0)

        assert latch.wait
        assert latch.wait(0)
        latch.count_down

        assert_equal 0, latch.count
      end

      def test_initial_count_must_be_a_non_negative_integer
        [-1, 1.5, "2", nil, Object.new].each do |count|
          assert_raises(ArgumentError) { CountDownLatch.new(count) }
        end
      end

      def test_count_down_stops_at_zero_and_wait_can_be_repeated
        latch = CountDownLatch.new(2)
        latch.count_down

        assert_equal 1, latch.count
        refute latch.wait(0)
        latch.count_down
        3.times { latch.count_down }

        assert_equal 0, latch.count
        3.times { assert latch.wait(0) }
      end

      def test_timeout_does_not_open_the_latch
        latch = CountDownLatch.new

        refute latch.wait(0.01)
        assert_equal 1, latch.count
        latch.count_down

        assert latch.wait(0)
      end

      def test_invalid_timeouts_do_not_change_the_count
        latch = CountDownLatch.new

        [-1, Float::INFINITY, Float::NAN].each do |timeout|
          assert_raises(ArgumentError) { latch.wait(timeout) }
          assert_equal 1, latch.count
        end
      end

      def test_all_thread_waiters_are_released
        latch = CountDownLatch.new(4)
        workers = 4.times.map { Thread.new { latch.wait(5) } }
        decrementers = 4.times.map { Thread.new { 10.times { latch.count_down } } }
        decrementers.each(&:value)

        assert_equal [true] * 4, workers.map(&:value)
        assert_equal 0, latch.count
      ensure
        [*workers, *decrementers].each { it.kill if it.alive? }
        [*workers, *decrementers].each(&:join)
      end

      def test_count_down_and_wait_across_ractors
        latch = CountDownLatch.new(2)
        workers = 2.times.map do
          Ractor.new(latch) do |shared|
            shared.count_down
            shared.wait(5)
          end
        end

        results = workers.map { ractor_value(it) }

        assert_equal [true, true], results
        assert_equal 0, latch.count
      end

      def test_wait_cooperates_with_a_fiber_scheduler
        return unless Fiber.respond_to?(:set_scheduler)

        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        latch = CountDownLatch.new(2)
        results = []
        3.times { Fiber.schedule { results << latch.wait(5) } }

        assert_empty results
        Fiber.schedule { latch.count_down }

        assert_empty results
        Fiber.schedule { latch.count_down }
        Fiber.set_scheduler(nil)

        assert_equal [true] * 3, results
      ensure
        Fiber.set_scheduler(nil) if Fiber.respond_to?(:set_scheduler)
      end

      def test_freezing_prevents_count_down_but_allows_waiting
        latch = CountDownLatch.new
        latch.freeze

        assert_predicate latch, :frozen?
        assert_raises(FrozenError) { latch.count_down }
        assert_equal 1, latch.count
        refute latch.wait(0)
      end

      def test_live_state_cannot_be_copied_or_marshaled
        latch = CountDownLatch.new

        assert_raises(TypeError) { latch.dup }
        assert_raises(TypeError) { latch.clone }
        assert_raises(TypeError) { Marshal.dump(latch) }
      end
    end
  end
end
