# frozen_string_literal: true

require_relative "../../setup"

module Farce
  class TestTreeMap < Test
    include Helpers::InternalTestHelpers

    LocalTreeMap = Internal::LocalTreeMap
    ShareableTreeMap = Internal::ShareableTreeMap
    TreeMap = Internal::TreeMap

    def test_empty_map
      map = TreeMap.new

      assert_kind_of TreeMap, map
      assert_empty map
      assert_equal 0, map.size
      assert_nil map.first_key
      assert_nil map.last_key
    end

    def test_map_with_entries
      map = TreeMap.new({ 10 => "a", 5 => "b" })

      assert_equal 2, map.size
      assert_equal 5, map.first_key
      assert_equal 10, map.last_key
      refute_empty map
      assert_equal "a", map[10]
      assert_equal "b", map[5]

      map[1] = "c"

      assert_equal 3, map.size
      assert_equal 1, map.first_key
      assert_equal 10, map.last_key
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

    [LocalTreeMap, TreeMap, ShareableTreeMap].uniq.each do |map_class|
      label = map_class.name.split("::").last

      define_method("test_#{label}_fetch_and_key_lookup") do
        stored = TreeMapLookupKey.new(1)
        equivalent = TreeMapLookupKey.new(1)
        missing = TreeMapLookupKey.new(2)
        map = map_class.new(stored => nil)

        assert_nil map.fetch(equivalent)
        assert_equal :default, map.fetch(missing, :default)
        assert_equal [:missing, missing], map.fetch(missing) { [:missing, it] }
        assert_raises(ArgumentError) { map.fetch }
        assert_raises(ArgumentError) { map.fetch(missing, :one, :two) }
        assert map.key?(equivalent)
        refute map.key?(missing)
        assert_same stored, map.getkey(equivalent)
        assert_nil map.getkey(missing)

        error = assert_raises(KeyError) { map.fetch(missing) }
        assert_same map, error.receiver
        assert_same missing, error.key
      end

      define_method("test_#{label}_each_is_ordered_and_uses_a_snapshot") do
        map = map_class.new(3 => :three, 1 => :one)
        enumerator = map.each

        assert_instance_of Enumerator, enumerator
        assert_equal 2, enumerator.size
        assert_equal [[1, :one], [3, :three]], enumerator.to_a

        visited = []
        result = map.each do |key, value|
          visited << [key, value]
          map[2] = :two if key == 1
        end

        assert_same map, result
        assert_equal [[1, :one], [3, :three]], visited
        assert_equal [[1, :one], [2, :two], [3, :three]], map.each.to_a
      end

      define_method("test_#{label}_canonicalizes_string_keys") do
        original = +"foo"
        equivalent = +"foo"
        canonical = -original
        map = map_class.new(original => :first)

        refute_same original, equivalent
        assert_same canonical, map.getkey(equivalent)
        assert_same canonical, map.first_key
        assert_predicate map.getkey(original), :frozen?
        assert map.key?(equivalent)
        assert_equal :first, map.fetch(equivalent)

        map[equivalent] = :second

        assert_equal 1, map.size
        assert_same canonical, map.getkey(+"foo")
        assert_equal :second, map.delete(+"foo")
        assert_empty map
      end

      define_method("test_#{label}_last_key_tracks_the_greatest_key") do
        map = map_class.new(2 => :two, 4 => :four, 1 => :one)

        assert_equal 4, map.last_key
        assert_equal [4, :four], map.pop
        assert_equal 2, map.last_key
        assert_equal [2, :two], map.pop
        assert_equal [1, :one], map.pop
        assert_nil map.pop
        assert_nil map.last_key
      end
    end

    def test_tree_map_variants_have_explicit_cruby_shareability
      map = TreeMap.new
      local = LocalTreeMap.new
      shareable = ShareableTreeMap.new

      if RUBY_ENGINE == "ruby"
        refute_predicate map, :frozen?
        refute Ractor.shareable?(map)
        refute Ractor.shareable?(local)
        assert_raises(Ractor::Error) { Ractor.make_shareable(map) }
        assert_predicate shareable, :frozen?
        assert Ractor.shareable?(shareable)
      else
        assert_same TreeMap, ShareableTreeMap
      end
    end

    def test_cruby_defines_all_three_native_maps_directly
      return unless RUBY_ENGINE == "ruby"

      assert_equal Object, LocalTreeMap.superclass
      assert_equal Object, TreeMap.superclass
      assert_equal Object, ShareableTreeMap.superclass
      assert_nil LocalTreeMap.instance_method(:[]=).source_location
      assert_nil TreeMap.instance_method(:[]=).source_location
      assert_nil ShareableTreeMap.instance_method(:[]=).source_location
    end

    def test_local_map_canonicalizes_mutable_string_keys
      original = +"middle"
      map = LocalTreeMap.new

      map[original] = :middle
      stored = map.getkey(+"middle")

      original.replace("zzzz")
      map["alpha"] = :alpha
      map["omega"] = :omega

      assert_equal :middle, map["middle"]
      assert_nil map["zzzz"]
      assert_same(-"middle", stored)
      assert_equal [["alpha", :alpha], ["middle", :middle], ["omega", :omega]],
        [map.shift, map.shift, map.shift]
    end

    def test_shareable_map_can_be_shared_between_cruby_ractors
      return unless RUBY_ENGINE == "ruby"

      map = ShareableTreeMap.new
      workers = 4.times.map do |worker|
        Ractor.new(map, worker) do |shared, prefix|
          100.times do |index|
            key = (prefix * 1_000) + index
            shared[key] = key
          end
        end
      end
      workers.each { ractor_value(it) }

      assert_equal 400, map.size
      assert_equal 0, map.first_key
      assert_equal 3_099, map[3_099]
    end

    def test_shareable_map_read_operations_work_from_another_cruby_ractor
      return unless RUBY_ENGINE == "ruby"

      map = ShareableTreeMap.new(2 => :two, 1 => :one)
      reader = Ractor.new(map) do |shared|
        [shared.fetch(1), shared.key?(2), shared.getkey(2), shared.last_key, shared.each.to_a]
      end

      assert_equal [:one, true, 2, 2, [[1, :one], [2, :two]]], ractor_value(reader)
    end

    def test_only_shareable_tree_map_rejects_unshareable_cruby_values
      return unless RUBY_ENGINE == "ruby"

      value = Object.new

      assert_raises(Ractor::IsolationError) { ShareableTreeMap.new[1] = value }
      assert_same value, TreeMap.new(1 => value)[1]
      assert_same value, LocalTreeMap.new(1 => value)[1]
    end

    def test_all_cruby_tree_maps_require_shareable_keys
      return unless RUBY_ENGINE == "ruby"

      [LocalTreeMap, TreeMap, ShareableTreeMap].each do |map_class|
        map = map_class.new
        key = Object.new

        assert_raises(Ractor::IsolationError) { map[key] }
        assert_raises(Ractor::IsolationError) { map[key] = :value }
        assert_raises(Ractor::IsolationError) { map.delete(key) }
      end
    end
  end

  class TreeMapLookupKey
    attr_reader :rank

    def initialize(rank)
      @rank = rank
      freeze
    end

    def <=>(other) = rank <=> other.rank
  end
end
