# frozen_string_literal: true

require_relative "../../setup"

module Farce
  module Unsafe
    class TestCounter < Test
      include Helpers::InternalTestHelpers

      def test_initialization_hierarchy_and_defaults
        counter = Counter.new

        assert_equal Abstract::Counter, Counter.superclass
        assert_instance_of Counter, counter
        assert_equal 0, counter.initial
        assert_equal 0, counter.value
        refute_predicate counter, :ractor_shareable?
        refute Ractor.shareable?(counter) if Internal.native_ractors?

        initialized = Counter.new("12")

        assert_equal 12, initialized.initial
        assert_equal 12, initialized.value
      end

      def test_increment_decrement_aliases_and_reset
        counter = Counter.new(10)

        assert_same counter, counter.increment
        assert_equal 11, counter.value
        assert_same counter, counter.add(4)
        assert_equal 15, counter.value
        assert_same counter, counter.decrement(3)
        assert_equal 12, counter.value
        assert_same counter, counter.subtract
        assert_equal 11, counter.value
        assert_same counter, counter.remove(2)
        assert_equal 9, counter.value
        assert_same counter, counter.reset
        assert_equal 10, counter.value
      end

      def test_integer_coercion_and_validation
        coercible = Object.new
        coercible.define_singleton_method(:to_int) { 7 }
        counter = Counter.new(coercible)

        assert_equal 7, counter.value
        assert_same counter, counter.increment("3")
        assert_equal 10, counter.value

        assert_raises(TypeError) { Counter.new(Object.new) }
        assert_raises(ArgumentError) { counter.increment("not an integer") }
        assert_equal 10, counter.value
      end

      def test_uses_rubys_arbitrary_precision_integers
        large = 2**200
        counter = Counter.new(large)

        counter.increment(large)

        assert_equal 2**201, counter.value
      end

      def test_numeric_interface_and_representation
        counter = Counter.new(6)

        assert_equal 8, counter + 2
        assert_equal 8, 2 + counter
        assert_equal 36, counter * counter
        assert_equal 0, counter <=> 6
        assert_equal 6, counter.to_i
        assert_in_delta 6.0, counter.to_f
        assert_equal 6, counter.unwrap
        assert_equal "#<Farce::Unsafe::Counter 6>", counter.inspect
      end

      def test_can_be_copied_between_ractors
        return unless Internal.native_ractors?

        counter = Counter.new(4)
        worker = Ractor.new do
          received = Ractor.receive
          received.increment(2)
          [received.class.name, received.value].freeze
        end

        worker.send(counter)

        assert_equal ["Farce::Unsafe::Counter", 6], ractor_value(worker)
        assert_equal 4, counter.value
      end

      def test_cannot_be_made_shareable
        return unless Internal.native_ractors?

        counter = Counter.new

        assert_raises(NoMethodError, Ractor::Error, TypeError) { Ractor.make_shareable(counter) }
        refute Ractor.shareable?(counter)
      end

      def test_can_be_moved_between_ractors
        return unless Internal.native_ractors?

        counter = Counter.new(7)
        worker = Ractor.new do
          received = Ractor.receive
          received.increment
          received.value
        end

        worker.send(counter, move: true)

        assert_equal 8, ractor_value(worker)
        assert_raises(Ractor::MovedError) { counter.value }
      end
    end
  end
end
