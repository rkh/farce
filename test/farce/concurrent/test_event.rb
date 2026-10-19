# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../../setup"

module Farce
  module Concurrent
    class TestEvent < Test
      include Helpers::InternalTestHelpers

      def test_initial_state_and_shareability
        event = Event.new

        refute event.wait(0)
        refute_predicate event, :set?
        refute_predicate event, :frozen?
        assert_predicate event, :ractor_shareable?
        assert Ractor.shareable?(event)
      end

      def test_set_is_idempotent_and_releases_future_waiters
        event = Event.new

        2.times { assert event.set }
        assert_predicate event, :set?
        assert event.wait
        assert event.wait(0)
      end

      def test_reset_is_idempotent_and_allows_reuse
        event = Event.new

        assert event.reset
        event.set

        assert event.reset
        refute_predicate event, :set?
        refute event.wait(0)
        assert_predicate event, :try?
        assert event.wait(0)
      end

      def test_try_only_succeeds_once_between_resets
        event = Event.new

        assert_predicate event, :try?
        refute_predicate event, :try?
        assert event.wait(0)
        event.reset

        assert_predicate event, :try?
      end

      def test_only_one_thread_can_set_the_event_with_try
        event = Event.new
        workers = 8.times.map { Thread.new { event.try? } }

        assert_equal 1, workers.count(&:value)
        assert event.wait(0)
      ensure
        workers&.each { it.kill if it.alive? }
        workers&.each(&:join)
      end

      def test_timeout_does_not_set_the_event
        event = Event.new

        refute event.wait(0.01)
        refute event.wait(0)
        event.set

        assert event.wait(0)
      end

      def test_invalid_timeouts_do_not_set_the_event
        event = Event.new

        [-1, Float::INFINITY, Float::NAN].each do |timeout|
          assert_raises(ArgumentError) { event.wait(timeout) }
          refute event.wait(0)
        end
      end

      def test_all_thread_waiters_are_released
        event = Event.new
        workers = 4.times.map { Thread.new { event.wait(5) } }
        event.set

        assert_equal [true] * 4, workers.map(&:value)
      ensure
        event&.set
        workers&.each { it.kill if it.alive? }
        workers&.each(&:join)
      end

      def test_wait_and_set_across_ractors
        event = Event.new
        worker = Ractor.new(event) { |shared| shared.wait(5) }
        event.set

        assert ractor_value(worker)
      end

      def test_wait_cooperates_with_a_fiber_scheduler
        return unless Fiber.respond_to?(:set_scheduler)

        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        event = Event.new
        results = []
        3.times { Fiber.schedule { results << event.wait(5) } }

        assert_empty results
        Fiber.schedule { event.set }
        Fiber.set_scheduler(nil)

        assert_equal [true] * 3, results
      ensure
        event&.set
        Fiber.set_scheduler(nil) if Fiber.respond_to?(:set_scheduler)
      end

      def test_reset_does_not_hide_a_set_from_current_waiters
        return unless Fiber.respond_to?(:set_scheduler)

        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        event = Event.new
        results = []
        3.times { Fiber.schedule { results << event.wait(0.05) } }

        assert_empty results
        Fiber.schedule do
          event.set
          event.reset
        end
        Fiber.set_scheduler(nil)

        assert_equal [true] * 3, results
        refute event.wait(0)
      ensure
        event&.set
        Fiber.set_scheduler(nil) if Fiber.respond_to?(:set_scheduler)
      end

      def test_freezing_prevents_state_changes_but_allows_waiting
        event = Event.new
        event.freeze

        assert_predicate event, :frozen?
        assert_raises(FrozenError) { event.set }
        assert_raises(FrozenError) { event.try? }
        assert_raises(FrozenError) { event.reset }
        refute event.wait(0)
      end

      def test_live_state_cannot_be_copied_or_marshaled
        event = Event.new

        assert_raises(TypeError) { event.dup }
        assert_raises(TypeError) { event.clone }
        assert_raises(TypeError) { Marshal.dump(event) }
      end
    end
  end
end
