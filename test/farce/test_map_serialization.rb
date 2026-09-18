# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "json"
require "psych"

module Farce
  class TestMapSerialization < Test
    def test_json_serialization
      map = Map.new({ one: 1, two: [2, 3] })
      expected = { "one" => 1, "two" => [2, 3] }
      compact = JSON.generate(map)
      pretty = JSON.pretty_generate(map)

      assert_equal expected, JSON.parse(compact)
      assert_equal expected, JSON.parse(pretty)
      assert_includes pretty, "\n"
    end

    def test_psych_round_trip
      map = Map.new(
        { one: 1, two: 2 },
        compare_keys_by_identity:   true,
        compare_values_by_identity: true,
      )

      restored = Psych.unsafe_load(Psych.dump(map))

      assert_instance_of Map, restored
      assert_equal map.to_h, restored.to_h
      assert_predicate restored, :compare_keys_by_identity?
      assert_predicate restored, :compare_values_by_identity?
    end

    def test_local_map_psych_round_trip
      map = Local::Map.new(
        { one: 1 },
        scope:                      :fiber,
        compare_keys_by_identity:   true,
        compare_values_by_identity: true,
      )
      map[:two] = 2

      restored = Psych.unsafe_load(Psych.dump(map))

      assert_instance_of Local::Map, restored
      assert_equal :fiber, restored.scope
      assert_equal({ one: 1, two: 2 }, restored.to_h)
      assert_predicate restored, :compare_keys_by_identity?
      assert_predicate restored, :compare_values_by_identity?
      assert_equal({ one: 1, two: 2 }, Fiber.new { restored.to_h }.resume)
      assert_equal 3, restored[:three] = 3
      assert_equal 3, restored[:three]
    end

    def test_bounded_map_psych_round_trip
      [LRUMap, Local::LRUMap].each do |type|
        options = {
          max_size:                   2,
          compare_keys_by_identity:   true,
          compare_values_by_identity: true,
        }
        options[:scope] = :fiber if type == Local::LRUMap
        map = type.new({ one: 1, two: 2 }, **options)

        restored = Psych.unsafe_load(Psych.dump(map))

        assert_instance_of type, restored
        assert_equal 2, restored.max_size
        assert_equal :fiber, restored.scope if type == Local::LRUMap

        assert_equal({ one: 1, two: 2 }, restored.to_h)
        assert_predicate restored, :compare_keys_by_identity?
        assert_predicate restored, :compare_values_by_identity?

        restored[:three] = 3

        assert_equal 2, restored.size
        assert_equal 3, restored[:three]
      end
    end
  end
end
