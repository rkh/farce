# frozen_string_literal: true

require_relative "../setup"

module Farce
  class TestCounter < Test
    include Helpers::InternalTestHelpers

    def test_initialization_and_shareability
      counter = Counter.new("12")

      assert_equal Internal::Counter, Counter.superclass
      assert_equal Numeric, Internal::Counter.superclass
      assert_kind_of Numeric, counter
      assert_kind_of Abstract::Value, counter
      assert_equal 12, counter.initial
      assert_equal 12, counter.value
      assert_predicate counter, :frozen?
      assert_predicate counter, :ractor_shareable?
      assert Ractor.shareable?(counter) if Internal.native_ractors?

      assert_equal 0, Counter.new.value
    end

    def test_initial_value_coercion_and_reinitialization
      coercible = Object.new
      coercible.define_singleton_method(:to_int) { 7 }
      counter = Counter.new(coercible)

      assert_equal 7, counter.initial
      assert_equal 7, counter.value
      assert_raises(FrozenError) { counter.send(:initialize, 9) }
      assert_equal 7, counter.initial
      assert_equal 7, counter.value
      assert_raises(TypeError) { Counter.new(Object.new) }
      assert_raises(ArgumentError) { Counter.new("invalid") }
    end

    def test_reset_retains_the_initial_integer_across_gc
      initial = (2**62) + 7
      counter = Counter.new(initial)
      counter.increment(10)
      GC.start
      GC.compact if GC.respond_to?(:compact)

      assert_equal initial + 10, counter.value
      assert_equal initial, counter.initial
      assert_same counter, counter.reset
      assert_equal initial, counter.value
    end

    def test_native_uninitialized_storage_is_not_accessible
      return unless Internal.native_ractors?
      counter = Counter.allocate
      counter.freeze

      assert Ractor.shareable?(counter)
      assert_raises(FrozenError) { counter.send(:initialize, 7) }
      assert_raises(RuntimeError) { counter.value }
      assert_raises(RuntimeError) { counter.increment }
    end

    def test_reentrant_initialization_does_not_overwrite_the_first_value
      counter = Counter.allocate
      coercible = Object.new
      coercible.define_singleton_method(:to_int) do
        counter.send(:initialize, 7)
        9
      end

      assert_raises(FrozenError) { counter.send(:initialize, coercible) }
      assert_equal 7, counter.initial
      assert_equal 7, counter.value
    end

    def test_increment_decrement_aliases_and_reset_return_self
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

    def test_increment_preserves_integer_coercion
      coercible = Object.new
      coercible.define_singleton_method(:to_int) { 7 }
      counter = Counter.new

      assert_same counter, counter.increment("3")
      assert_equal 3, counter.value
      assert_same counter, counter.increment(2.9)
      assert_equal 5, counter.value
      assert_same counter, counter.increment(Rational(5, 2))
      assert_equal 7, counter.value
      assert_same counter, counter.increment(coercible)
      assert_equal 14, counter.value
      assert_same counter, counter.increment(-4)
      assert_equal 10, counter.value
    end

    def test_coercion_can_reenter_the_counter_before_incrementing
      counter = Counter.new(1)
      coercible = Object.new
      coercible.define_singleton_method(:to_int) do
        counter.increment(10)
        2
      end

      assert_same counter, counter.increment(coercible)
      assert_equal 13, counter.value
    end

    def test_invalid_arguments_do_not_change_the_value
      counter = Counter.new(7)

      assert_raises(TypeError) { counter.increment(Object.new) }
      assert_raises(TypeError) { counter.increment(nil) }
      assert_raises(ArgumentError) { counter.increment("invalid") }
      assert_raises(ArgumentError) { counter.increment(1, 2) }
      assert_raises(TypeError) { counter.decrement(Object.new) }
      assert_raises(TypeError) { counter.decrement(nil) }
      assert_raises(ArgumentError) { counter.decrement("invalid") }
      assert_raises(ArgumentError) { counter.decrement(1, 2) }
      assert_raises(ArgumentError) { counter.value(1) }
      assert_equal 7, counter.value
    end

    def test_native_range_checks_do_not_change_the_value
      return unless RUBY_ENGINE == "ruby"
      maximum = (2**63) - 1
      minimum = -(2**63)
      counter = Counter.new(maximum)

      assert_raises(RangeError) { counter.increment }
      assert_equal maximum, counter.value
      assert_raises(RangeError) { counter.increment(minimum - 1) }
      assert_equal maximum, counter.value
      assert_same counter, counter.increment(minimum)
      assert_equal(-1, counter.value)

      counter = Counter.new(minimum)

      assert_raises(RangeError) { counter.decrement }
      assert_equal minimum, counter.value
      assert_raises(RangeError) { counter.increment(maximum + 1) }
      assert_equal minimum, counter.value
      assert_raises(RangeError) { counter.decrement(minimum - 1) }
      assert_equal minimum, counter.value
      assert_same counter, counter.decrement(minimum)
      assert_equal 0, counter.value
      assert_raises(RangeError) { counter.decrement(minimum) }
      assert_equal 0, counter.value

      counter = Counter.new(maximum)

      assert_raises(RangeError) { counter.decrement(-1) }
      assert_equal maximum, counter.value
    end

    def test_numeric_interface_uses_the_current_value
      counter = Counter.new(6)
      counter.increment

      assert_equal 9, counter + 2
      assert_equal 9, 2 + counter
      assert_equal 49, counter * counter
      assert_equal 0, counter <=> 7
      assert_equal 7, counter.to_i
      assert_equal 7, counter.unwrap
      assert_equal "#<Farce::Counter 7>", counter.inspect
    end

    def test_subclasses_can_override_and_call_super
      subclass = Class.new(Counter) do
        def increment(by = 1) = super(by * 2)
        def decrement(by = 1) = super(by * 3)
        def value = super + 1
      end
      counter = subclass.new

      assert_same counter, counter.add(3)
      assert_equal 7, counter.value
      assert_same counter, counter.decrement
      assert_equal 4, counter.value
    end

    def test_decrement_coerces_the_amount_to_an_integer_before_subtracting
      coercible = Object.new
      coercible.define_singleton_method(:to_int) { 7 }
      counter = Counter.new(20)

      assert_same counter, counter.decrement("3")
      assert_equal 17, counter.value
      assert_same counter, counter.decrement(2.9)
      assert_equal 15, counter.value
      assert_same counter, counter.decrement(Rational(5, 2))
      assert_equal 13, counter.value
      assert_same counter, counter.decrement(coercible)
      assert_equal 6, counter.value
      assert_same counter, counter.decrement(-4)
      assert_equal 10, counter.value
    end

    def test_updates_are_exact_across_threads
      counter = Counter.new
      workers = 8.times.map do
        Thread.new { 2_000.times { counter.increment } }
      end
      workers.each(&:value)

      assert_equal 16_000, counter.value
    end

    def test_updates_are_exact_across_ractors_and_threads
      return unless Internal.native_ractors?
      counter = Counter.new
      workers = 4.times.map do
        Ractor.new(counter) do |shared|
          threads = 2.times.map do
            Thread.new { 2_000.times { shared.increment.decrement.increment } }
          end
          threads.each(&:value)
          shared.object_id
        end
      end
      object_ids = workers.map { |worker| ractor_value(worker) }

      assert_equal [counter.object_id], object_ids.uniq
      assert_equal 16_000, counter.value
    end
  end
end
