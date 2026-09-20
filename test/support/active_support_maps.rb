# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "farce/integrations/active_support"

module Farce
  class ActiveSupportMapTests < Test
    MAPS = [Map, Strict::Map, Unshared::Map, Local::Map,
            WeakKeyMap, Strict::WeakValueMap, Strict::WeakMap,
            Unshared::WeakKeyMap, Unshared::WeakValueMap, Unshared::WeakMap,
            Local::WeakKeyMap, Local::WeakValueMap, Local::WeakMap,
            TreeMap, Strict::TreeMap, Unshared::TreeMap, Unsafe::TreeMap, Local::TreeMap,
            LRUMap, Strict::LRUMap, Unshared::LRUMap, Unsafe::LRUMap, Local::LRUMap,
            LFUMap, Strict::LFUMap, Unshared::LFUMap, Unsafe::LFUMap, Local::LFUMap].freeze

    def test_methods_belong_to_the_correct_capabilities
      %i[as_json to_query to_param assert_valid_keys].each do |method|
        assert_equal Abstract::Map, Map.instance_method(method).owner
      end
      %i[deep_dup stringify_keys symbolize_keys to_options compact_blank reverse_merge with_defaults].each do |method|
        assert_equal Abstract::DuplicableMap, Map.instance_method(method).owner
      end
      %i[compact_blank! reverse_merge! with_defaults!].each do |method|
        assert_equal Abstract::ConcurrentMap, Map.instance_method(method).owner
        refute TreeMap.method_defined?(method)
        refute LeaseMap.method_defined?(method)
      end
      refute Map.method_defined?(:reverse_update)
    end

    def test_shallow_copy_operations_preserve_map_kind_and_source
      MAPS.each do |type|
        source = new_map(type, { a: 1, b: nil, c: false })
        results = {
          source.stringify_keys                => { "a" => 1, "b" => nil, "c" => false },
          source.compact_blank                 => { a: 1 },
          source.reverse_merge({ a: 9, d: 4 }) => { a: 1, b: nil, c: false, d: 4 },
          source.with_defaults({ a: 9, d: 4 }) => { a: 1, b: nil, c: false, d: 4 },
        }
        results.each do |copy, entries|
          assert_instance_of type, copy
          assert_equal entries, copy.to_h
          assert_equal source.max_size, copy.max_size if source.is_a?(Abstract::BoundedMap)
          assert Ractor.shareable?(copy) if source.is_a?(Shareable)
          copy.clear
        end
        strings = new_map(type, { "a" => 1 })

        assert_instance_of type, strings.symbolize_keys
        assert_equal({ a: 1 }, strings.symbolize_keys.to_h)
        assert_equal({ a: 1 }, strings.to_options.to_h)
        assert_equal({ a: 1, b: nil, c: false }, source.to_h)
      end
    end

    def test_deep_dup_copies_nested_maps_and_values
      %i[copy move].each do |mode|
        source = Map.new({ a: [[2]] }, mode:)
        copy = source.deep_dup
        value = copy[:a]
        value.first << 3

        assert_instance_of Map, copy
        assert_equal mode, copy.mode
        assert_equal [[2]], source[:a]
      end
      nested = Unshared::Map.new({ child: [1] })
      source = Unshared::Map.new({ a: { nested: } })
      copy = source.deep_dup
      copy[:a][:nested][:child] << 2

      assert_instance_of Unshared::Map, copy[:a][:nested]
      assert_equal [1], source[:a][:nested][:child]
      value = [1].freeze
      strict = Strict::Map.new({ a: value })

      if Internal.native_ractors?
        assert_raises(Ractor::IsolationError) { strict.deep_dup }
      else
        refute_same value, strict.deep_dup[:a]
      end

      assert_same value, strict[:a]
      MAPS.each do |type|
        source = new_map(type, { a: 1, b: nil })

        assert_instance_of type, source.deep_dup
        assert_equal source.to_h, source.deep_dup.to_h
      end
    end

    def test_deep_dup_preserves_identity_strings_and_duplicates_other_keys
      string = String.new("key").freeze
      array = [1]
      source = Unshared::Map.new({ string => [2], array => [3] }, compare_by_identity: true)
      copy = source.deep_dup

      assert_predicate copy, :compare_by_identity?
      assert_predicate copy, :compare_values_by_identity?
      assert_same string, copy.getkey(string)
      refute_same source[string], copy[string]
      copied_key = copy.keys.find { Array === it }

      assert_equal array, copied_key
      refute_same array, copied_key
      assert_equal [3], copy[copied_key]
    end

    def test_defaults_preserve_existing_nil_false_and_normalize_once
      source = Unshared::Map.new({ 1 => nil, 2 => false }, normalize_keys: :succ)
      defaults = Unshared::Map.new({ 1 => 9, 2 => 9, 3 => 4 })

      assert_equal({ 2 => nil, 3 => false, 4 => 4 }, source.reverse_merge(defaults).to_h)
      assert_equal source.to_h, source.deep_dup.to_h
      assert_same source, source.reverse_merge!(defaults)
      assert_same source, source.with_defaults!({ 3 => 8 })
      assert_equal({ 2 => nil, 3 => false, 4 => 4 }, source.to_h)
      assert_raises(TypeError) { source.reverse_merge([]) }
      assert_raises(TypeError) { source.reverse_merge!([]) }
      coercible = Object.new
      def coercible.to_hash = { 4 => 5 }

      assert_equal 5, source.reverse_merge(coercible)[4]
      assert_same source, source.reverse_merge!(coercible)
      %i[copy move].each do |mode|
        input = { b: [2] }
        map = Map.new({ a: [1] }, mode:)
        copy = map.reverse_merge(input)

        assert_equal({ a: [1], b: [2] }, copy.to_h)
        assert_equal({ a: [1] }, map.to_h)
        assert_equal({ b: [2] }, input)
      end
      bounded = LRUMap.new({ a: 1 }, max_size: 1)

      assert_equal({ a: 1 }, bounded.reverse_merge({ a: 9, b: 2 }).to_h)
    end

    def test_defaults_preserve_identity_settings_and_skip_existing_move_values
      first = String.new("key").freeze
      second = String.new("key").freeze
      source = Unshared::Map.new({ first => 1 }, compare_by_identity: true)
      copy = source.reverse_merge({ second => 2 })

      assert_predicate copy, :compare_keys_by_identity?
      assert_predicate copy, :compare_values_by_identity?
      assert_equal 1, copy[first]
      assert_equal 2, copy[second]
      value = [2]
      moved = Map.new({ a: nil }, mode: :move)

      assert_same moved, moved.reverse_merge!({ a: value })
      assert_equal [2], value
      assert_nil moved[:a]
      return unless Internal.native_ractors?
      strict = Strict::Map.new

      assert_raises(Ractor::IsolationError) { strict.reverse_merge!({ a: 1, b: [] }) }
      assert_equal({ a: 1 }, strict.to_h)
    end

    def test_blank_values_and_failed_symbol_conversion
      entries = { missing: nil, disabled: false, space: " ", array: [], hash: {}, zero: 0, enabled: true }
      source = Unshared::Map.new(entries)

      assert_equal({ zero: 0, enabled: true }, source.compact_blank.to_h)
      assert_equal entries, source.to_h
      assert_same source, source.compact_blank!
      assert_equal({ zero: 0, enabled: true }, source.to_h)
      key = Object.new
      def key.to_sym = raise ArgumentError, "cannot convert"
      source = Unshared::Map.new({ key => 1 })

      assert_same key, source.symbolize_keys.keys.first
    end

    def test_blank_compaction_and_atomic_defaults
      MAPS.select { it < Abstract::ConcurrentMap }.each do |type|
        map = new_map(type, { a: nil, b: false, c: "", d: 1 })

        assert_same map, map.compact_blank!
        assert_equal({ d: 1 }, map.to_h)
        assert_same map, map.compact_blank!
        assert_same map, map.reverse_merge!({ d: 9, e: 2 })
        assert_equal({ d: 1, e: 2 }, map.to_h)
      end
      map = Unshared::Map.new
      entered = Thread::Queue.new
      release = Thread::Queue.new
      worker = Thread.new do
        map.store_if_absent(:a) do
          entered << true
          release.pop
          nil
        end
      end
      begin
        entered.pop
        merger = Thread.new { map.reverse_merge!({ a: :default, b: 2 }) }
        release << true
        worker.value

        assert_same map, merger.value
        assert_equal({ a: nil, b: 2 }, map.to_h)
      ensure
        worker.kill if worker.alive?
        merger&.kill if merger&.alive?
      end
    end

    def test_query_encoding_validation_and_key_conversion
      map = Unshared::Map.new({ a: [1, 2], b: Unshared::Map.new({ c: "a b" }) })
      hash = { a: [1, 2], b: { c: "a b" } }

      assert_equal hash.to_query, map.to_query
      assert_equal hash.to_query("root"), map.to_query("root")
      assert_equal hash.to_param, map.to_param
      assert_same map, map.assert_valid_keys(%i[a b])
      assert_raises(ArgumentError) { map.assert_valid_keys("a", "b") }
      assert_equal "", Unshared::Map.new.to_query
      normalized = Unshared::Map.new({ "a" => 1 }, normalize_keys: :to_sym)

      assert_same normalized, normalized.assert_valid_keys(:a)
      assert_raises(ArgumentError) { normalized.assert_valid_keys("a") }
      assert_equal({ a: 1 }, normalized.stringify_keys.to_h)
      mixed = Unshared::Map.new({ 1 => 2, "a" => 3 })

      assert_equal({ 1 => 2, a: 3 }, mixed.symbolize_keys.to_h)
    end

    private

    def new_map(type, entries)
      options = type < Abstract::BoundedMap ? { max_size: 5 } : {}
      type.new(entries, **options)
    end
  end
end
