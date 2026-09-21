# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestMapFreeze < Test
    HASH_FREEZE_TARGET = :farce_hash_freeze_target
    TREE_FREEZE_TARGET = :farce_tree_freeze_target
    private_constant :HASH_FREEZE_TARGET, :TREE_FREEZE_TARGET

    class FreezingHashKey
      def hash
        Thread.current[HASH_FREEZE_TARGET]&.freeze
        1
      end

      def eql?(other) = equal?(other)
    end
    private_constant :FreezingHashKey

    class FreezingTreeKey
      def <=>(other)
        Thread.current[TREE_FREEZE_TARGET]&.freeze
        object_id <=> other.object_id
      end
    end
    private_constant :FreezingTreeKey

    class FreezingNthHashKey
      def initialize(freeze_at)
        @calls = Counter.new
        @freeze_at = freeze_at
        freeze
      end

      def hash
        Thread.current[HASH_FREEZE_TARGET]&.freeze if @calls.increment == @freeze_at
        1
      end

      def eql?(other) = equal?(other)
    end
    private_constant :FreezingNthHashKey

    class FreezingEqualityKey
      def initialize(id)
        @id = id
        freeze
      end

      def hash = 1

      def eql?(other)
        equal = other.is_a?(FreezingEqualityKey) && @id == other.instance_variable_get(:@id)
        Thread.current[HASH_FREEZE_TARGET]&.freeze if equal
        equal
      end
    end
    private_constant :FreezingEqualityKey

    class NestedMutationHashKey
      def initialize(outer, inner)
        @outer = outer
        @inner = inner
        @calls = Counter.new
      end

      def hash
        if @calls.increment == 2
          @inner[:nested] = :committed
          @outer.freeze
        end
        1
      end

      def eql?(other) = equal?(other)
    end
    private_constant :NestedMutationHashKey

    MAP_TYPES = [
      Map,
      Strict::Map,
      TreeMap,
      Strict::TreeMap,
      LRUMap,
      Strict::LRUMap,
      LFUMap,
      Strict::LFUMap,
      WeakKeyMap,
      Strict::WeakKeyMap,
      Strict::WeakValueMap,
      Strict::WeakMap
    ].freeze
    private_constant :MAP_TYPES

    def test_map_copies_have_independent_logical_freeze_state
      MAP_TYPES.each do |type|
        source = new_map(type, key: :source)
        source.freeze
        duplicate = source.dup
        frozen_clone = source.clone
        mutable_clone = source.clone(freeze: false)

        refute_predicate duplicate, :frozen?, type.name
        assert_predicate frozen_clone, :frozen?, type.name
        refute_predicate mutable_clone, :frozen?, type.name
        assert Ractor.shareable?(duplicate)
        assert Ractor.shareable?(frozen_clone)
        assert Ractor.shareable?(mutable_clone)

        duplicate[:key] = :duplicate
        mutable_clone[:key] = :mutable_clone

        assert_equal :source, source[:key], type.name
        assert_equal :source, frozen_clone[:key], type.name
        assert_equal :duplicate, duplicate[:key], type.name
        assert_equal :mutable_clone, mutable_clone[:key], type.name
      end
    end

    def test_normalized_map_is_structurally_published_without_logical_freeze
      map = Map.new({ key: :value }, normalize_keys: :to_sym)
      backend = map.instance_variable_get(:@map)

      assert Ractor.shareable?(map)
      assert Object.instance_method(:frozen?).bind_call(backend)
      refute_predicate map, :frozen?
      assert_equal :value, map["key"]

      map["second"] = :stored

      assert_equal :stored, map[:second]
    end

    def test_key_hash_cannot_freeze_map_and_then_commit
      map = Map.new
      key = FreezingHashKey.new.freeze
      Thread.current[HASH_FREEZE_TARGET] = map

      assert_raises(FrozenError) { map[key] = :value }
      assert_predicate map, :frozen?
      assert_empty map
    ensure
      Thread.current[HASH_FREEZE_TARGET] = nil
    end

    def test_jvm_native_write_hash_callback_cannot_commit_after_freezing
      return if RUBY_ENGINE == "ruby"

      map = Map.new
      key = FreezingNthHashKey.new(2)
      Thread.current[HASH_FREEZE_TARGET] = map

      assert_raises(FrozenError) { map[key] = :value }
      assert_predicate map, :frozen?
      assert_empty map
      assert_empty map.instance_variable_get(:@map).instance_variable_get(:@reservations)
    ensure
      Thread.current[HASH_FREEZE_TARGET] = nil
    end

    def test_jvm_native_write_equality_callback_cannot_commit_after_freezing
      return if RUBY_ENGINE == "ruby"

      existing = FreezingEqualityKey.new(:key)
      replacement = FreezingEqualityKey.new(:key)
      map = Map.new({ existing => :existing })
      Thread.current[HASH_FREEZE_TARGET] = map

      assert_raises(FrozenError) { map[replacement] = :replacement }
      assert_predicate map, :frozen?
      assert_equal :existing, map[existing]
      assert_equal 1, map.size
      assert_empty map.instance_variable_get(:@map).instance_variable_get(:@reservations)
    ensure
      Thread.current[HASH_FREEZE_TARGET] = nil
    end

    def test_jvm_nested_map_callback_restores_outer_mutation_owner
      return if RUBY_ENGINE == "ruby"

      outer = Map.new
      inner = Map.new
      key = NestedMutationHashKey.new(outer, inner)

      assert_raises(FrozenError) { outer[key] = :rejected }
      assert_predicate outer, :frozen?
      assert_empty outer
      assert_empty outer.instance_variable_get(:@map).instance_variable_get(:@reservations)
      assert_equal :committed, inner[:nested]
    end

    def test_jvm_update_block_freeze_cleans_reservation_before_commit
      return if RUBY_ENGINE == "ruby"

      map = Map.new({ key: :original })

      assert_raises(FrozenError) do
        map.update(:key) do
          map.freeze
          :rejected
        end
      end

      assert_predicate map, :frozen?
      assert_equal :original, map[:key]
      assert_empty map.instance_variable_get(:@map).instance_variable_get(:@reservations)
    end

    def test_tree_comparison_cannot_freeze_map_and_then_commit
      existing = FreezingTreeKey.new.freeze
      inserted = FreezingTreeKey.new.freeze
      map = TreeMap.new(existing => :existing)
      Thread.current[TREE_FREEZE_TARGET] = map

      assert_raises(FrozenError) { map[inserted] = :inserted }
      assert_predicate map, :frozen?
      assert_equal [[existing, :existing]], map.to_a
    ensure
      Thread.current[TREE_FREEZE_TARGET] = nil
    end

    def test_frozen_tree_reads_do_not_consult_mutation_state
      map = TreeMap.new(2 => :two, 1 => :one, 3 => :three)
      map.freeze

      assert_equal :two, map[2]
      assert_equal :two, map.fetch(2)
      assert_nil map[4]
      assert_equal :missing, map.fetch(4, :missing)
      assert map.key?(1)
      refute map.key?(4)
      assert_equal 2, map.getkey(2)
      assert_equal 1, map.first_key
      assert_equal 3, map.last_key
      assert_equal [[1, :one], [2, :two], [3, :three]], map.to_a
    end

    def test_reentrant_freeze_happens_before_move_wrapping
      map = Map.new(mode: :move)
      payload = ModePayload.new(:available)

      assert_raises(FrozenError) do
        map.store_if_absent(:key) do
          map.freeze
          payload
        end
      end

      assert_equal :available, payload.value
      assert_empty map
    end

    def test_normalizer_freeze_happens_before_move_wrapping
      normalizer = Ractor.shareable_proc do |key|
        Thread.current[HASH_FREEZE_TARGET]&.freeze
        key
      end
      map = Map.new(mode: :move, normalize_keys: normalizer)
      payload = ModePayload.new(:available)
      Thread.current[HASH_FREEZE_TARGET] = map

      assert_raises(FrozenError) { map.store(:key, payload) }
      assert_equal :available, payload.value
      assert_empty map
    ensure
      Thread.current[HASH_FREEZE_TARGET] = nil
    end

    private

    def new_map(type, entries)
      options = type < Abstract::BoundedMap ? { max_size: 2 } : {}
      type.new(entries, **options)
    end
  end
end
