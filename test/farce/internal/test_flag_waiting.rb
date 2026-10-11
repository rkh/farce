# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../../setup"

module Farce
  module Internal
    class TestFlagWaiting < Test
      include Helpers::InternalTestHelpers

      def test_wait_until_changed_returns_the_changed_boolean
        [false, true].each do |initial|
          flag = flag_class.new(initial).freeze

          assert_equal initial, flag.wait_until_changed(!initial, timeout: 0) { flunk "unexpected timeout" }
        end
      end

      def test_wait_until_changed_timeout_and_fallback
        flag = flag_class.new

        assert_nil flag.wait_until_changed(false, timeout: 0)
        calls = 0

        assert_equal :expired, flag.wait_until_changed(false, timeout: 0.01) {
          calls += 1
          :expired
        }
        assert_equal 1, calls
        assert_equal 0, wait_signal(flag).num_waiting
      end

      def test_wait_until_changed_validates_arguments
        flag = flag_class.new

        [nil, 0, :true].each do |expected| # rubocop:disable Lint/BooleanSymbol
          assert_raises(ArgumentError) { flag.wait_until_changed(expected, timeout: 0) }
        end
        [-1, Float::INFINITY, Float::NAN].each do |timeout|
          assert_raises(ArgumentError) { flag.wait_until_changed(true, timeout:) }
        end
      end

      def test_wait_until_changed_wakes_all_waiters_for_each_mutator
        operations = [
          [false, lambda(&:set)],
          [true, lambda(&:unset)],
          [false, ->(flag) { flag.store(true) }],
          [true, ->(flag) { flag.value = false }],
          [false, ->(flag) { flag.swap(true) }],
          [true, ->(flag) { flag.compare_and_set(true, false) }],
          [false, lambda(&:toggle)]
        ]
        operations.each do |initial, change|
          flag = flag_class.new(initial)
          waiters = 3.times.map { Thread.new { flag.wait_until_changed(initial, timeout: 5) } }
          Timeout.timeout(5) { Thread.pass until wait_signal(flag).num_waiting == waiters.size }
          change.call(flag)
          waiters.each do |waiter|
            assert waiter.join(5), "flag change did not wake waiter"
            assert_equal !initial, waiter.value
          end
          assert_equal 0, wait_signal(flag).num_waiting
        ensure
          waiters&.each { |waiter| waiter.kill.join }
        end
      end

      def test_wait_until_changed_does_not_return_for_unchanged_writes
        flag = flag_class.new
        writer = Thread.new do
          Timeout.timeout(5) { Thread.pass until wait_signal(flag).num_waiting == 1 }
          flag.set if flag.compare_and_set(true, true)
          flag.store(false)
        end

        assert_equal :expired, flag.wait_until_changed(false, timeout: 0.1) { :expired }
        writer.value
      ensure
        writer&.kill&.join
      end

      def test_copies_have_independent_wait_signals
        flag = flag_class.new
        [flag.dup, flag.clone].each do |copy|
          refute_same wait_signal(flag), wait_signal(copy)
          copy.set

          refute flag.value
          assert copy.wait_until_changed(false, timeout: 0)
        end
      end

      def test_wait_until_changed_across_ractors
        return unless Internal.native_ractors?
        flag = flag_class.new
        worker = Ractor.new(flag) { |shared| shared.wait_until_changed(false, timeout: 5) }
        Timeout.timeout(5) { Thread.pass until wait_signal(flag).num_waiting == 1 }
        flag.set

        assert ractor_value(worker)
      ensure
        flag&.set unless flag&.frozen?
      end

      def test_wait_until_changed_does_not_block_a_fiber_scheduler
        return unless Fiber.respond_to?(:set_scheduler)
        scheduler = Helpers::QueueTestScheduler.new
        flag = flag_class.new
        events = []
        Fiber.set_scheduler(scheduler)
        Fiber.schedule { events << flag.wait_until_changed(false, timeout: 5) }
        Fiber.schedule do
          events << wait_signal(flag).num_waiting
          flag.set
        end
        Fiber.set_scheduler(nil)

        assert_equal [1, true], events
      ensure
        Fiber.set_scheduler(nil) if Fiber.respond_to?(:set_scheduler)
      end

      private

      def flag_class = Flag
      def wait_signal(flag) = flag.send(:change_signal)
    end
  end

  class TestFlagWaiting < Internal::TestFlagWaiting
    private def flag_class = Flag
  end
end
