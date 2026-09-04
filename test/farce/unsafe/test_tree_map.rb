# frozen_string_literal: true

require_relative "../../setup"

module Farce
  module Unsafe
    class TestTreeMap < Test
      include Helpers::InternalTestHelpers

      def test_initialization_hierarchy_and_properties
        map = TreeMap.new([[2, :two], [1, :one]])

        assert_equal Abstract::TreeMap, TreeMap.superclass
        assert_instance_of TreeMap, map
        assert_instance_of Internal::LocalTreeMap, map.instance_variable_get(:@map)
        assert_equal [[1, :one], [2, :two]], map.to_a
        assert_predicate map, :shareable_keys?
        refute_predicate map, :shareable_values?
        refute_predicate map, :compare_keys_by_identity?
        refute_predicate map, :compare_values_by_identity?
        refute_predicate map, :compare_by_identity?
        refute_predicate map, :weak_keys?
        refute_predicate map, :weak_values?
        refute_predicate map, :ractor_shareable?
      end

      def test_ordered_crud_and_nil_values
        map = TreeMap.new

        assert_nil map[2]
        assert_equal :three, map[3] = :three
        assert_nil map[1] = nil
        assert_equal :two, map[2] = :two

        assert_equal 3, map.size
        assert_equal 3, map.length
        assert_equal 1, map.first_key
        assert_equal 3, map.last_key
        assert map.key?(1)
        assert_nil map[1]
        assert_equal :two, map.fetch(2)
        assert_equal :missing, map.fetch(4, :missing)
        assert_same map, map.fetch(4) { map }
        assert_equal 2, map.getkey(2)
        assert_nil map.getkey(4)
        assert_equal :two, map.delete(2)
        assert_nil map.delete(2)
        refute map.key?(2)
      end

      def test_iteration_is_ordered_and_uses_a_snapshot
        map = TreeMap.new(3 => :three, 1 => :one)
        enumerator = map.each

        assert_instance_of Enumerator, enumerator
        assert_equal [[1, :one], [3, :three]], enumerator.to_a

        visited = []
        result = map.each do |key, value|
          visited << [key, value]
          map[2] = :two if key == 1
        end

        assert_same map, result
        assert_equal [[1, :one], [3, :three]], visited
        assert_equal [[1, :one], [2, :two], [3, :three]], map.each_pair.to_a
        assert_equal [1, 2, 3], map.each_key.to_a
        assert_equal %i[one two three], map.each_value.to_a
        assert_equal [1, 2, 3], map.keys
        assert_equal %i[one two three], map.values
        assert_predicate map.keys, :frozen?
        assert_predicate map.values, :frozen?
      end

      def test_map_convenience_methods
        map = TreeMap.new(1 => { nested: :value }, 2 => nil)

        assert_equal [1, { nested: :value }], map.assoc(1)
        assert_nil map.assoc(3)
        assert_equal :value, map.dig(1, :nested)
        assert_nil map.dig(2, :nested)
        assert_equal [{ nested: :value }, nil, :missing], map.fetch_values(1, 2, 3) { :missing }
        assert_equal [{ nested: :value }, nil, nil], map.values_at(1, 2, 3)
        assert_equal({ 1 => { nested: :value }, 2 => nil }, map.to_h)
        assert_includes map, 1
        assert map.method(:member?).call(2)
        assert map.method(:has_key?).call(2)
        refute_includes map, 3
      end

      def test_shift_pop_and_clear
        map = TreeMap.new(2 => :two, 1 => :one, 3 => :three)

        assert_equal [1, :one], map.shift
        assert_equal [3, :three], map.pop
        assert_equal [2, :two], map.shift
        assert_nil map.shift
        assert_nil map.pop
        assert_predicate map, :empty?

        map[1] = :one

        assert_same map, map.clear
        assert_predicate map, :empty?
        assert_same map, map.clear
      end

      def test_mutable_strings_are_stored_as_canonical_keys
        original = +"middle"
        canonical = -original
        map = TreeMap.new(original => :value)

        stored = map.getkey(+"middle")
        original.replace("changed")

        assert_same canonical, stored
        assert_predicate stored, :frozen?
        assert_equal :value, map["middle"]
        assert_nil map["changed"]
      end

      def test_values_are_stored_without_copying
        value = []
        map = TreeMap.new(1 => value)

        assert_same value, map[1]

        value << :changed

        assert_equal [:changed], map[1]
      end

      def test_cannot_be_shared_or_transferred_between_ractors
        return unless Internal.native_ractors?

        map = TreeMap.new

        refute Ractor.shareable?(map)
        assert_transfer_rejected { TreeMap.new }
      end

      private

      def assert_transfer_rejected
        copy_receiver = Ractor.new { Ractor.receive }
        move_receiver = Ractor.new { Ractor.receive }

        assert_raises(Ractor::Error, IOError, TypeError) { copy_receiver.send(yield) }
        assert_raises(Ractor::Error, IOError, TypeError) { move_receiver.send(yield, move: true) }

        copy_receiver.send(:stop)

        assert_equal :stop, ractor_value(copy_receiver)
        copy_receiver = nil

        move_receiver.send(:stop)

        assert_equal :stop, ractor_value(move_receiver)
        move_receiver = nil
      ensure
        stop_receiver(copy_receiver)
        stop_receiver(move_receiver)
      end

      def stop_receiver(receiver)
        return unless receiver
        receiver.send(:stop)
        ractor_value(receiver)
      rescue Ractor::ClosedError
        nil
      end
    end
  end
end
