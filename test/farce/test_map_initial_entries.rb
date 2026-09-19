# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestMapInitialEntries < Test
    MAPS = [
      Map, WeakKeyMap, Strict::Map, Strict::WeakKeyMap, Strict::WeakValueMap, Strict::WeakMap,
      Unshared::Map, Unshared::WeakKeyMap, Unshared::WeakValueMap, Unshared::WeakMap,
      Local::Map, Local::WeakKeyMap, Local::WeakValueMap, Local::WeakMap,
      TreeMap, Strict::TreeMap, Unshared::TreeMap, Unsafe::TreeMap, Local::TreeMap,
      LRUMap, Strict::LRUMap, Unshared::LRUMap, Unsafe::LRUMap, Local::LRUMap,
      LFUMap, Strict::LFUMap, Unshared::LFUMap, Unsafe::LFUMap, Local::LFUMap
    ].freeze

    class Entries
      def initialize(pairs)
        @pairs = pairs
        @used = false
      end

      def each
        raise "source iterated twice" if @used
        @used = true
        @pairs.each { |key, value| yield key, value } # rubocop:disable Style/ExplicitBlockArgument
      end
    end

    def test_maps_accept_maps_arrays_and_each_only_sources
      MAPS.each do |type|
        sources = [
          Unshared::Map.new({ a: 1, b: 2 }), [[:a, 1], [:b, 2]],
          [[:a, 1], [:b, 2]].each, Entries.new([[:a, 1], [:b, 2]])
        ]
        sources.each do |source|
          map = build(type, source)

          assert_equal({ a: 1, b: 2 }, map.to_h, type.name)
        end
        assert_empty build(type, [])
        assert_raises(TypeError) { build(type, Object.new) }
      end
    end

    def test_entries_are_normalized_sequentially
      MAPS.each do |type|
        source = Entries.new([["a", 1], [:a, 2], [:b, 3]])
        map = build(type, source, normalize_keys: :to_sym)

        assert_equal({ a: 2, b: 3 }, map.to_h, type.name)
      end
    end

    def test_initial_entries_preserve_identity
      [Unshared::Map, Local::Map, Strict::Map].each do |type|
        first = String.new("a").freeze
        second = String.new("a").freeze
        map = build(type, Entries.new([[first, 1], [second, 2]]), compare_keys_by_identity: true)

        assert_equal 2, map.size
        assert_equal 1, map[first]
        assert_equal 2, map[second]
      end
    end

    def test_local_entries_are_consumed_once_and_reused_in_each_scope
      source = Entries.new([[:a, 1]])
      map = Local::Map.new(source, scope: :fiber)

      assert_equal 1, map[:a]
      assert_equal 1, Fiber.new { map[:a] }.resume
    end

    def test_bounded_entries_keep_eviction_order
      [LRUMap, Unshared::LRUMap, Local::LRUMap].each do |type|
        map = type.new(Entries.new([[:a, 1], [:b, 2], [:c, 3], [:a, 4]]), max_size: 2)

        assert_equal({ c: 3, a: 4 }, map.to_h)
      end
    end

    def test_lease_initializers_accept_each_only_sources
      [LeaseMap, Unshared::LeaseMap, Local::LeaseMap].each do |type|
        map = type.new(normalize_keys: :to_sym) { Entries.new([["a", []]]) }

        assert_equal [:a], map.keys
        assert_empty map.checkout(:a, &:dup)
      end
    end

    private

    def build(type, entries, **options)
      options[:max_size] = 10 if type < Abstract::BoundedMap
      type.new(entries, **options)
    end
  end
end
