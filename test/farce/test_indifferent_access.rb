# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestIndifferentAccess < Test
    MAPS = [
      Map, WeakKeyMap, Strict::Map, Strict::WeakKeyMap, Strict::WeakValueMap, Strict::WeakMap,
      Unshared::Map, Unshared::WeakKeyMap, Unshared::WeakValueMap, Unshared::WeakMap,
      Local::Map, Local::WeakKeyMap, Local::WeakValueMap, Local::WeakMap,
      TreeMap, Strict::TreeMap, Unshared::TreeMap, Unsafe::TreeMap, Local::TreeMap,
      LRUMap, Strict::LRUMap, Unshared::LRUMap, Unsafe::LRUMap, Local::LRUMap,
      LFUMap, Strict::LFUMap, Unshared::LFUMap, Unsafe::LFUMap, Local::LFUMap
    ].freeze

    def test_returns_an_independent_map_of_the_same_kind
      MAPS.each do |type|
        options = type < Abstract::BoundedMap ? { max_size: 3 } : {}
        original = type.new({ a: 1 }, **options)
        copy = original.with_indifferent_access

        assert_kind_of Abstract::DuplicableMap, original
        assert_predicate original, :duplicable?
        assert_instance_of type, copy
        refute_same original, copy
        assert_equal 1, copy[:a]
        assert_equal 1, copy["a"]
        assert_equal ["a"], copy.keys
        copy["b"] = 2

        assert_equal 2, copy[:b]
        refute original.key?(:b)
        assert_equal [:a], original.keys
        assert_equal 3, copy.max_size if type < Abstract::BoundedMap
      end
    end

    def test_preserves_other_keys_and_does_not_convert_nested_values
      nested = { a: 1 }
      original = Unshared::Map.new({ a: nested, 1 => :number, nil => :nil })
      copy = original.with_indifferent_access

      assert_same nested, copy[:a]
      assert_equal :number, copy[1]
      assert_nil copy["1"]
      assert_equal :nil, copy[nil]
      assert_equal({ a: 1 }, nested)
    end

    def test_uses_key_equality_even_for_identity_maps
      original = Unshared::Map.new({ a: 1 }, compare_by_identity: true)
      copy = original.with_indifferent_access

      refute_predicate copy, :compare_keys_by_identity?
      assert_predicate copy, :compare_values_by_identity?
      assert_equal 1, copy[String.new("a")]
    end

    def test_preserves_mode_without_moving_values_out_of_the_source
      original = Map.new({ a: [1] }, mode: :move)
      copy = original.with_indifferent_access

      assert_equal :move, copy.mode
      assert_equal [1], original[:a]
      assert_equal [1], copy["a"]
    end

    def test_preserves_local_scope_and_initializes_new_scopes
      original = Local::Map.new({ a: 1 }, scope: :fiber)
      copy = original.with_indifferent_access

      assert_equal :fiber, copy.scope
      assert_equal 1, Fiber.new { copy["a"] }.resume
    end

    def test_copy_replaces_existing_normalization
      original = Unshared::Map.new({ 1 => :value }, normalize_keys: :succ)
      copy = original.with_indifferent_access

      assert_equal :value, copy[2]
      assert_nil copy[3]
      copy[:a] = :added

      assert_equal :added, copy["a"]
    end

    def test_lease_maps_do_not_offer_copying_operations
      [LeaseMap, Unshared::LeaseMap, Local::LeaseMap].each do |type|
        original = type.new { { a: [1] } }

        refute_respond_to original, :with_indifferent_access
        refute_predicate original, :duplicable?
        assert_raises(NoMethodError) { original.with_indifferent_access }
        assert_equal [1], original.checkout(:a, &:dup)
      end
    end

    def test_lease_maps_can_normalize_keys_at_construction
      [LeaseMap, Unshared::LeaseMap, Local::LeaseMap].each do |type|
        normalizer = Ractor.shareable_proc { |key| Symbol === key ? key.name : key }
        original = type.new(normalize_keys: normalizer) { { a: [1] } }

        assert_same original.lease_for(:a), original.lease_for("a")
        assert_equal [1], original.checkout("a", &:dup)
      end
    end
  end
end
