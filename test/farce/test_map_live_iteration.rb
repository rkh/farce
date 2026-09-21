# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestMapLiveIteration < Test
    TYPES = [Map, Strict::Map, Unshared::Map, Local::Map,
             Strict::WeakMap, Unshared::WeakMap, Local::WeakMap].freeze

    def test_live_iteration_yields_all_entries_without_mutation
      entries = 100.times.to_h { [it, it * 2] }
      TYPES.each do |type|
        map = type.new(entries)

        assert_equal entries, map.each_live.to_h, type.name
        assert_same(map, map.each_live { |_key, _value| nil })
      end
    end

    def test_deletion_during_live_iteration_does_not_skip_remaining_entries
      TYPES.each do |type|
        map = type.new(100.times.to_h { [it, true] })
        observed = []
        map.each_live do |key, value|
          observed << key

          assert value
          map.delete(key)
        end

        assert_equal (0...100).to_a, observed.sort, type.name
        assert_empty map, type.name
      end
    end

    def test_insertion_does_not_hold_a_lock_across_yield
      TYPES.each do |type|
        map = type.new(100.times.to_h { [it, true] })
        inserted = false

        begin
          map.each_live do |_key, _value|
            next if inserted
            map[101] = true
            inserted = true
          end
        rescue RuntimeError => e
          assert_match(/structurally changed/, e.message, type.name)
        end

        assert inserted, "#{type.name} did not invoke the iterator block"
        assert_equal 101, map.size, type.name
        assert_equal 101, map.each_live.count, type.name
      end
    end

    def test_value_modes_and_key_normalization_are_preserved
      value = [1]
      map = Map.new({ "ONE" => value }, mode: :local, normalize_keys: :downcase)
      pair = map.each_live.first

      assert_equal "one", pair.first
      assert_same value, pair.last
    end

    def test_partial_iteration_can_be_closed_before_reusing_map
      TYPES.each do |type|
        map = type.new(100.times.to_h { [it, true] })

        assert_equal 1, map.each_live.take(1).size, type.name
        map[101] = true

        assert_equal 101, map.each_live.count, type.name
      end
    end
  end
end
