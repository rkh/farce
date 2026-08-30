# frozen_string_literal: true

require_relative "../../setup"

module Farce
  class TestTreeMap < Test
    TreeMap = Internal::TreeMap

    def test_empty_map
      map = TreeMap.new

      assert_kind_of TreeMap, map
      assert_empty map
      assert_equal 0, map.size
      assert_nil map.first_key
    end

    def test_map_with_entries
      map = TreeMap.new({ 10 => "a", 5 => "b" })

      assert_equal 2, map.size
      assert_equal 5, map.first_key
      refute_empty map
      assert_equal "a", map[10]
      assert_equal "b", map[5]

      map[1] = "c"

      assert_equal 3, map.size
      assert_equal 1, map.first_key
      assert_equal "c", map[1]
      refute_empty map
      assert_equal "a", map[10]
      assert_equal "b", map[5]
    end

    def test_shift
      map = TreeMap.new({ 10 => "a", 5 => "b" })

      assert_equal [5, "b"], map.shift
      assert_equal 1, map.size
      assert_equal 10, map.first_key

      assert_equal [10, "a"], map.shift
      assert_empty map
      assert_nil map.first_key
    end
  end
end
