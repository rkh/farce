# frozen_string_literal: true

require_relative "../../setup"

module Farce
  module Internal
    class TestExchanger < Test
      include Helpers::InternalTestHelpers

      def test_initialization
        exchanger = Exchanger.new

        assert_predicate exchanger, :frozen?
        assert Ractor.shareable?(exchanger)
      end

      def test_two_threads_exchange_values
        exchanger = Exchanger.new
        first = Thread.new { exchanger.exchange(:first) }
        second = Thread.new { exchanger.exchange(:second) }

        assert_equal :second, first.value
        assert_equal :first, second.value
      end

      def test_nil_supports_one_way_handoff
        exchanger = Exchanger.new
        sender = Thread.new { exchanger.exchange(:payload) }
        receiver = Thread.new { exchanger.exchange(nil) }

        assert_nil sender.value
        assert_equal :payload, receiver.value
      end

      def test_timeout_and_fallback
        exchanger = Exchanger.new

        assert_nil exchanger.exchange(:value, timeout: 0)
        assert_equal :fallback, exchanger.exchange(:value, timeout: 0.01) { :fallback }
      end

      def test_invalid_timeout
        exchanger = Exchanger.new

        assert_raises(ArgumentError) { exchanger.exchange(:value, timeout: -1) }
        assert_raises(ArgumentError) { exchanger.exchange(:value, timeout: Float::INFINITY) }
      end

      def test_rejects_unshareable_values
        return unless Internal.native_ractors?

        exchanger = Exchanger.new

        assert_raises(Ractor::IsolationError) { exchanger.exchange(Object.new, timeout: 0) }
      end

      def test_many_callers_pair_without_losing_values
        exchanger = Exchanger.new
        values = 20.times.map { |index| index }
        threads = values.map { |value| Thread.new { exchanger.exchange(value) } }
        received = threads.map(&:value)

        assert_equal values.sort, received.sort
        values.each_with_index do |value, index|
          refute_equal value, received[index]
        end
      end

      def test_interrupted_waiter_does_not_capture_the_next_exchange
        exchanger = Exchanger.new
        interrupted = Thread.new { exchanger.exchange(:interrupted) }
        Timeout.timeout(1) { Thread.pass until interrupted.status == "sleep" }
        interrupted.kill.join

        first = Thread.new { exchanger.exchange(:first, timeout: 1) }
        second = Thread.new { exchanger.exchange(:second, timeout: 1) }

        assert_equal :second, first.value
        assert_equal :first, second.value
      end

      def test_ractors_exchange_values
        exchanger = Exchanger.new
        first = Ractor.new(exchanger) { |shared| shared.exchange(:first) }
        second = Ractor.new(exchanger) { |shared| shared.exchange(:second) }

        assert_equal :second, ractor_value(first)
        assert_equal :first, ractor_value(second)
      end
    end
  end
end
