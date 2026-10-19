# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../../setup"

module Farce
  module Concurrent
    class TestTuple < Test
      include Helpers::InternalTestHelpers

      def run(...) = Timeout.timeout(15) { super }

      def test_initial_size_and_shareability
        tuple = Tuple.new(3)

        assert_equal 3, tuple.size
        assert_equal [nil, nil, nil], tuple.to_a
        assert_predicate tuple, :ractor_shareable?
        assert Ractor.shareable?(tuple)
        refute_predicate tuple, :frozen?
      end

      def test_zero_size_stays_empty
        tuple = Tuple.new(0)

        assert_equal 0, tuple.size
        assert_empty tuple.to_a
        [-1, 0, 1].each do |index|
          assert_nil tuple.get(index)
          assert_nil tuple.volatile_get(index)
          assert_nil tuple.set(index, :value)
          assert_nil tuple.volatile_set(index, :value)
          refute tuple.compare_and_set(index, nil, :value)
        end
        assert_equal 0, tuple.size
        assert_empty tuple.to_a
      end

      def test_size_is_converted_to_an_integer
        tuple = Tuple.new("3")

        assert_equal 3, tuple.size
        assert_equal [nil, nil, nil], tuple.to_a
      end

      def test_invalid_sizes
        assert_raises(ArgumentError) { Tuple.new(-1) }
        assert_raises(ArgumentError) { Tuple.new("invalid") }
        [nil, Object.new].each do |size|
          assert_raises(TypeError) { Tuple.new(size) }
        end
      end

      def test_getters_and_setters_preserve_nil_false_and_values
        %i[set volatile_set].each do |setter|
          tuple = Tuple.new(3)
          value = +"value"

          assert_nil tuple.public_send(setter, 0, nil)
          assert_same false, tuple.public_send(setter, 1, false)
          assert_same value, tuple.public_send(setter, 2, value)
          %i[get volatile_get].each do |getter|
            assert_nil tuple.public_send(getter, 0)
            assert_same false, tuple.public_send(getter, 1)
            assert_equal "value", tuple.public_send(getter, 2)
          end
          assert_equal 3, tuple.size
        end
      end

      def test_getters_return_nil_for_out_of_bounds_indexes
        tuple = Tuple.new(2)
        tuple.set(0, :first)
        tuple.set(1, :last)
        [-3, -1, 2, 3].each do |index|
          assert_nil tuple.get(index)
          assert_nil tuple.volatile_get(index)
        end

        assert_equal %i[first last], tuple.to_a
      end

      def test_setters_ignore_out_of_bounds_indexes
        tuple = Tuple.new(2)
        tuple.set(0, :first)
        tuple.set(1, :last)
        [-3, -1, 2, 3].each do |index|
          assert_nil tuple.set(index, :changed)
          assert_nil tuple.volatile_set(index, :changed)
        end

        assert_equal 2, tuple.size
        assert_equal %i[first last], tuple.to_a
      end

      def test_compare_and_set_only_replaces_a_matching_value
        tuple = Tuple.new(2)

        assert tuple.compare_and_set(0, nil, false)
        assert_same false, tuple.get(0)
        refute tuple.compare_and_set(0, nil, :wrong)
        assert_same false, tuple.get(0)
        assert tuple.compare_and_set(0, false, :replacement)
        refute tuple.compare_and_set(0, :wrong, nil)
        assert_equal :replacement, tuple.get(0)
        assert tuple.compare_and_set(0, :replacement, nil)
        assert_equal [nil, nil], tuple.to_a
      end

      def test_cas_alias
        tuple = Tuple.new(1)

        assert tuple.cas(0, nil, :value)
        refute tuple.cas(0, nil, :wrong)
        assert_equal :value, tuple.get(0)
        refute tuple.cas(-1, :value, :wrong)
        refute tuple.cas(1, nil, :wrong)
        assert_equal [:value], tuple.to_a
      end

      def test_compare_and_set_ignores_out_of_bounds_indexes
        tuple = Tuple.new(2)

        [-3, -1, 2, 3].each do |index|
          refute tuple.compare_and_set(index, nil, :changed)
        end

        assert_equal 2, tuple.size
        assert_equal [nil, nil], tuple.to_a
      end

      def test_each_yields_values_in_order_and_returns_self
        tuple = Tuple.new(3)
        tuple.set(1, false)
        tuple.set(2, :last)
        visited = []

        assert_same(tuple, tuple.each { visited << it })
        assert_equal [nil, false, :last], visited
        empty = Tuple.new(0)

        assert_same(empty, empty.each { flunk "empty tuple" })
      end

      def test_each_without_a_block_and_enumerable_methods
        tuple = Tuple.new(3)
        tuple.set(1, false)
        tuple.set(2, :last)
        enumerator = tuple.each

        assert_instance_of Enumerator, enumerator
        assert_equal [nil, false, :last], enumerator.to_a
        assert_equal [true, false, false], tuple.map(&:nil?)
        assert_equal 3, tuple.count
      end

      def test_compare_and_set_is_atomic_across_threads
        tuple = Tuple.new(1)
        tuple.set(0, 0)
        start = ::Queue.new
        workers = 4.times.map do
          Thread.new do
            start.pop
            100.times do
              loop do
                current = tuple.get(0)
                break if tuple.compare_and_set(0, current, current + 1)
              end
            end
          end
        end
        4.times { start << true }
        workers.each(&:value)

        assert_equal 400, tuple.get(0)
        assert_equal 1, tuple.size
      ensure
        workers&.each { it.kill if it.alive? }
        workers&.each(&:join)
      end

      def test_compare_and_set_is_atomic_across_ractors
        tuple = Tuple.new(1)
        tuple.set(0, 0)
        workers = 2.times.map do
          Ractor.new(tuple) do |shared|
            100.times do
              loop do
                current = shared.volatile_get(0)
                break if shared.compare_and_set(0, current, current + 1)
              end
            end
            shared.object_id
          end
        end
        identities = workers.map { ractor_value(it) }

        assert_equal [tuple.object_id] * 2, identities
        assert_equal 200, tuple.get(0)
        assert_equal 1, tuple.size
      end

      def test_can_be_constructed_in_another_ractor
        worker = Ractor.new { Tuple.new(2) }
        tuple = ractor_value(worker)

        assert Ractor.shareable?(tuple)
        refute_predicate tuple, :frozen?
        assert_equal 2, tuple.size
        assert_equal :value, tuple.set(1, :value)
        assert_equal [nil, :value], tuple.to_a
      end

      def test_marshal_restores_values_and_independent_shareable_storage
        tuple = Tuple.new(4)
        nested = Vector.new([1])
        tuple.set(1, false)
        tuple.set(2, "value")
        tuple.set(3, nested)
        copy = Marshal.load(Marshal.dump(tuple))

        assert_instance_of Tuple, copy
        assert_equal 4, copy.size
        assert_equal [nil, false, "value"], copy.to_a.first(3)
        assert_predicate copy.get(2), :frozen?
        assert Ractor.shareable?(copy)
        refute_predicate copy, :frozen?
        assert copy.cas(1, false, true)
        copy.set(0, :changed)
        copy.get(3) << 2

        assert_nil tuple.get(0)
        assert_same false, tuple.get(1)
        assert_equal [1], nested.to_a
        assert_equal [1, 2], copy.get(3).to_a
      end

      def test_marshal_preserves_empty_and_frozen_tuples
        [0, 1].each do |size|
          tuple = Tuple.new(size).freeze
          copy = Marshal.load(Marshal.dump(tuple))

          assert_equal size, copy.size
          assert_equal ::Array.new(size), copy.to_a
          assert_predicate copy, :frozen?
          assert Ractor.shareable?(copy)
          next if size.zero?

          assert_raises(FrozenError) { copy.set(0, :changed) }
          assert_raises(FrozenError) { copy.cas(0, nil, :changed) }
        end
      end

      def test_marshaled_tuple_can_be_loaded_and_used_in_another_ractor
        tuple = Tuple.new(1)
        tuple.set(0, :before)
        worker = Ractor.new(Marshal.dump(tuple)) do |snapshot|
          restored = Marshal.load(snapshot) # rubocop:disable Security/MarshalLoad
          raise "tuple is not shareable" unless Ractor.shareable?(restored)
          raise "CAS failed" unless restored.cas(0, :before, :after)
          restored
        end
        copy = ractor_value(worker)

        assert Ractor.shareable?(copy)
        assert_equal :after, copy.get(0)
        assert_equal :before, tuple.get(0)
        assert copy.cas(0, :after, :main)
      end

      def test_freezing_prevents_writes_and_allows_reads
        tuple = Tuple.new(1)
        tuple.set(0, :value)

        assert_same tuple, tuple.freeze
        assert_predicate tuple, :frozen?
        assert_raises(FrozenError) { tuple.set(0, :changed) }
        assert_raises(FrozenError) { tuple.volatile_set(0, :changed) }
        assert_raises(FrozenError) { tuple.compare_and_set(0, :value, :changed) }
        assert_raises(FrozenError) { tuple.cas(0, :value, :changed) }
        assert_equal :value, tuple.get(0)
        assert_equal :value, tuple.volatile_get(0)
        assert_equal [:value], tuple.each.to_a
      end
    end
  end
end
