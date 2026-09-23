# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestMapAccess < Test
    MAP_TYPES = [Map, Strict::Map, Unshared::Map].freeze

    class EqualityString < String
      def eql?(_other) = raise("custom equality")
    end

    def test_default_mode_preserves_a_deeply_frozen_graph
      leaf = Object.new.freeze
      graph = [[leaf].freeze].freeze
      map = Map.new

      map[:first] = graph

      assert_same graph, map[:first]

      map[:second] = graph

      assert_same graph, map[:second]
    end

    def test_native_local_and_copy_modes_handle_partially_frozen_graphs
      return unless Map.instance_method(:[]=).source_location.nil?

      local_child = []
      local_graph = [local_child].freeze
      local_map = Map.new(mode: :local)

      local_map[:key] = local_graph

      assert_same local_graph, local_map[:key]
      assert_same local_child, local_map[:key].first

      copy_child = []
      copy_graph = [copy_child].freeze
      copy_map = Map.new(mode: :copy)

      copy_map[:key] = copy_graph
      stored = copy_map[:key]

      assert_equal [[]], stored
      refute_same copy_graph, stored
      refute_same copy_child, stored.first

      copy_child << :changed

      assert_equal [[]], copy_map[:key]
    end

    def test_assignment_rejects_a_bad_key_before_moving_the_value
      key = ModePayload.new(:key)
      value = ModePayload.new(:available)
      map = Map.new(mode: :move)

      assert_raises(Ractor::IsolationError) { map[key] = value }
      assert_equal :available, value.value
      assert_empty map
    end

    def test_assignment_prepares_an_aliased_string_key_before_moving_the_value
      value = +"aliased"
      map = Map.new(mode: :move)

      map[value] = value

      assert_equal "aliased", map["aliased"]
      assert_equal "aliased", map.getkey("aliased")
      assert_predicate map.getkey("aliased"), :frozen?
    end

    def test_distinct_strings_preserve_encoding_equality_and_original_keys
      pairs = [
        [String.new("key"), String.new("key")],
        ["ascii".encode(Encoding::UTF_8), "ascii".encode(Encoding::US_ASCII)],
        ["é".encode(Encoding::UTF_8), "é".b],
        ["long" * 1024, "long" * 1024]
      ]
      MAP_TYPES.each do |type|
        pairs.each do |stored, lookup|
          stored.freeze
          lookup.freeze
          map = type.new({ stored => :first })
          matches = stored.eql?(lookup)

          if matches
            assert_equal :first, map[lookup]
          else
            assert_nil map[lookup]
          end
          map[lookup] = :second

          assert_equal :second, map[lookup]
          assert_equal(matches ? 1 : 2, map.size)
          assert_same stored, map.getkey(stored)
          assert_equal(matches ? :second : :first, map[stored])
        end
      end
    end

    def test_native_string_subclass_equality_errors_release_the_map
      return unless MAP_TYPES.all? { |type| type.instance_method(:[]).source_location.nil? }

      MAP_TYPES.each do |type|
        key = EqualityString.new("key").freeze
        lookup = String.new("key").freeze
        map = type.new({ key => :first })

        error = assert_raises(RuntimeError) { map[lookup] }
        assert_equal "custom equality", error.message
        assert_equal :first, map[key]
        assert_raises(RuntimeError) { map[lookup] = :second }
        assert_equal :first, map[key]
        map[key] = :updated

        assert_equal :updated, map[key]
      end
    end
  end
end
