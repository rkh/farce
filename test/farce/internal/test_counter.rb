# frozen_string_literal: true

require_relative "../../setup"

module Farce
  module Internal
    class TestCounter < Test
      include Helpers::InternalTestHelpers

      MINIMUM = -(2**63)
      MAXIMUM = (2**63) - 1

      def test_default_and_initial_value
        assert_equal 0, Counter.new.value
        assert_equal 42, Counter.new(42).value
        assert_equal MINIMUM, Counter.new(MINIMUM).value
        assert_equal MAXIMUM, Counter.new(MAXIMUM).value
      end

      def test_counter_is_frozen_and_shareable
        return unless Internal.native_ractors?
        counter = Counter.new

        assert_predicate counter, :frozen?
        assert Ractor.shareable?(counter)
      end

      def test_frozen_uninitialized_counter_cannot_be_initialized
        return unless Internal.native_ractors?
        counter = Counter.allocate
        counter.freeze

        assert Ractor.shareable?(counter)
        assert_raises(FrozenError) { counter.send(:initialize, 7) }
        assert_raises(RuntimeError) { counter.value }
      end

      def test_initial_value_must_be_an_integer_in_signed_64_bit_range
        assert_raises(TypeError) { Counter.new(1.0) }
        assert_raises(TypeError) { Counter.new("1") }
        return unless RUBY_ENGINE == "ruby"
        assert_raises(RangeError) { Counter.new(MINIMUM - 1) }
        assert_raises(RangeError) { Counter.new(MAXIMUM + 1) }
      end

      def test_value_get_store_writer_and_swap
        counter = Counter.new(1)

        assert_equal 1, counter.value
        assert_equal 1, counter.get
        assert_equal 2, counter.store(2)
        assert_equal 2, counter.value
        assert_equal 3, counter.value = 3
        assert_equal 3, counter.get
        assert_equal 3, counter.swap(4)
        assert_equal 4, counter.value
      end

      def test_store_and_swap_validate_before_mutating
        return unless RUBY_ENGINE == "ruby"
        counter = Counter.new(7)

        assert_raises(TypeError) { counter.store(7.0) }
        assert_equal 7, counter.value
        assert_raises(RangeError) { counter.store(MAXIMUM + 1) }
        assert_equal 7, counter.value
        assert_raises(TypeError) { counter.swap("8") }
        assert_equal 7, counter.value
        assert_raises(RangeError) { counter.swap(MINIMUM - 1) }
        assert_equal 7, counter.value
      end

      def test_add_and_subtract_return_the_new_value
        counter = Counter.new(5)

        assert_equal 6, counter.add
        assert_equal 9, counter.add(3)
        assert_equal 7, counter.subtract(2)
        assert_equal 11, counter.subtract(-4)
        assert_equal 10, counter.add(-1)
        assert_equal 10, counter.value
      end

      def test_increment_and_decrement_accept_optional_deltas
        counter = Counter.new

        assert_equal 1, counter.increment
        assert_equal 4, counter.increment(3)
        assert_equal 3, counter.decrement
        assert_equal(-1, counter.decrement(4))
        assert_equal(-1, counter.value)
      end

      def test_arithmetic_requires_an_integer_delta
        counter = Counter.new(5)

        assert_raises(TypeError) { counter.add(1.0) }
        assert_equal 5, counter.value
        assert_raises(TypeError) { counter.subtract("1") }
        assert_equal 5, counter.value

        return unless RUBY_ENGINE == "ruby"
        assert_raises(RangeError) { counter.increment(MAXIMUM + 1) }
        assert_equal 5, counter.value
        assert_raises(RangeError) { counter.decrement(MINIMUM - 1) }
        assert_equal 5, counter.value
      end

      def test_overflow_raises_without_changing_the_value
        return unless RUBY_ENGINE == "ruby"
        maximum = Counter.new(MAXIMUM)
        minimum = Counter.new(MINIMUM)

        assert_raises(RangeError) { maximum.increment }
        assert_equal MAXIMUM, maximum.value
        assert_raises(RangeError) { maximum.subtract(-1) }
        assert_equal MAXIMUM, maximum.value

        assert_raises(RangeError) { minimum.decrement }
        assert_equal MINIMUM, minimum.value
        assert_raises(RangeError) { minimum.add(-1) }
        assert_equal MINIMUM, minimum.value
      end

      def test_subtract_handles_the_minimum_delta_without_c_overflow
        return unless RUBY_ENGINE == "ruby"
        counter = Counter.new(-1)

        assert_equal MAXIMUM, counter.subtract(MINIMUM)

        counter.store(0)
        assert_raises(RangeError) { counter.subtract(MINIMUM) }
        assert_equal 0, counter.value
      end

      def test_compare_and_set
        counter = Counter.new(10)

        assert counter.compare_and_set(10, 20)
        assert_equal 20, counter.value
        refute counter.compare_and_set(10, 30)
        assert_equal 20, counter.value
        assert counter.compare_and_set(20, MINIMUM)
        assert_equal MINIMUM, counter.value
      end

      def test_compare_and_set_validates_both_arguments_before_mutating
        counter = Counter.new(10)

        assert_raises(TypeError) { counter.compare_and_set(10.0, 20) }
        assert_equal 10, counter.value
        assert_raises(TypeError) { counter.compare_and_set(99, "20") }
        assert_equal 10, counter.value

        return unless RUBY_ENGINE == "ruby"
        assert_raises(RangeError) { counter.compare_and_set(MAXIMUM + 1, 20) }
        assert_equal 10, counter.value
        assert_raises(RangeError) { counter.compare_and_set(99, MINIMUM - 1) }
        assert_equal 10, counter.value
      end

      def test_updates_are_exact_across_threads
        counter = Counter.new
        thread_count = 8
        increments_per_thread = 1_000
        threads = thread_count.times.map do
          Thread.new do
            increments_per_thread.times.map { counter.increment }
          end
        end
        returned_values = threads.flat_map(&:value)

        assert_equal thread_count * increments_per_thread, counter.value
        assert_equal (1..(thread_count * increments_per_thread)).to_a,
          returned_values.sort
      end

      def test_updates_are_exact_across_ractors
        return unless Internal.native_ractors?
        counter = Counter.new
        ractor_count = 4
        increments_per_ractor = 1_000
        workers = ractor_count.times.map do
          Ractor.new(counter, increments_per_ractor) do |shared, count|
            count.times { shared.increment }
            shared.object_id
          end
        end
        worker_object_ids = workers.map { |worker| ractor_value(worker) }

        assert_equal ractor_count * increments_per_ractor, counter.value
        assert_equal [counter.object_id], worker_object_ids.uniq
      end

      def test_counter_sent_to_a_ractor_is_the_same_object
        counter = Counter.new(1)
        worker = Ractor.new do
          received = Ractor.receive
          received.increment
          received.object_id
        end

        worker << counter

        assert_equal counter.object_id, ractor_value(worker)
        assert_equal 2, counter.value
      end
    end
  end
end
