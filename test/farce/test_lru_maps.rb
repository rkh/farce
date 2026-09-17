# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestLRUMaps < Test
    include Helpers::InternalTestHelpers

    DIRECT_MAPS = [LRUMap, Strict::LRUMap, Unshared::LRUMap, Unsafe::LRUMap].freeze

    def test_abstract_factory_errors
      assert_raises(NoMethodError) { Abstract::LRUMap.new(max_size: 1) }

      subclass = Class.new(Abstract::LRUMap)
      error = assert_raises(RuntimeError) { subclass.new(max_size: 1) }

      assert_match(/subclass failed to implement #new_bounded_map/, error.message)
    end

    def test_public_hierarchy_backends_and_properties
      assert_equal Abstract::LRUMap, LRUMap.superclass
      assert_equal Abstract::LRUMap, Strict::LRUMap.superclass
      assert_equal Abstract::LRUMap, Unshared::LRUMap.superclass
      assert_equal Abstract::LRUMap, Unsafe::LRUMap.superclass
      assert_equal Abstract::LRUMap, Local::LRUMap.superclass
      assert_instance_of Internal::StrictLRUMap, LRUMap.new(max_size: 1).instance_variable_get(:@map)
      assert_instance_of Internal::StrictLRUMap, Strict::LRUMap.new(max_size: 1).instance_variable_get(:@map)
      assert_instance_of Internal::LRUMap, Unshared::LRUMap.new(max_size: 1).instance_variable_get(:@map)
      assert_instance_of Internal::LRUMap, Unsafe::LRUMap.new(max_size: 1).instance_variable_get(:@map)

      local = Local::LRUMap.new(max_size: 1)

      assert_instance_of Internal::LRUMap, Internal::Storage[local].map

      [LRUMap, Strict::LRUMap].each do |klass|
        map = klass.new(max_size: 1)

        assert_predicate map, :shareable_keys?
        assert_predicate map, :shareable_values?
        assert_predicate map, :ractor_shareable?
        assert_predicate map, :frozen?
        assert Ractor.shareable?(map)
      end

      [Unshared::LRUMap, Local::LRUMap].each do |klass|
        map = klass.new(max_size: 1)

        refute_predicate map, :shareable_keys?
        refute_predicate map, :shareable_values?
      end

      refute_predicate Unshared::LRUMap.new(max_size: 1), :ractor_shareable?
      assert_predicate local, :ractor_shareable?
      assert_predicate local, :frozen?
      assert Ractor.shareable?(local)
    end

    def test_common_protocol_nil_false_and_observational_semantics
      DIRECT_MAPS.each do |klass|
        map = klass.new([[nil, false], [false, nil], [:three, 3]], max_size: 3)

        refute map[nil]
        assert_nil map[false]
        assert map.key?(false)
        assert_same false, map.getkey(false)
        assert_equal({ nil => false, false => nil, three: 3 }, map.to_h)

        map.key?(:three)
        map.getkey(:three)
        map.each.to_a
        map.keys
        map.values

        assert_equal({ nil => false, false => nil, three: 3 }, map.to_h)
        assert_equal 3, map.fetch(:three)
        map[:four] = 4

        refute map.key?(nil)
        assert_equal({ false => nil, three: 3, four: 4 }, map.to_h)
        assert_equal [false, nil], map.shift
        assert_equal 1, map.prune(to: 1)
        assert_equal({ four: 4 }, map.to_h)
        assert_same map, map.clear
        assert_empty map
      end
    end

    def test_comparison_configuration_is_delegated
      [*DIRECT_MAPS, Local::LRUMap].each do |klass|
        map = klass.new(max_size: 2, compare_by_identity: true)

        assert_predicate map, :compare_by_identity?
        assert_predicate map, :compare_keys_by_identity?
        assert_predicate map, :compare_values_by_identity?
      end
    end

    def test_mode_map_copies_and_unwraps_values
      source = ModePayload.new(:initial)
      map = LRUMap.new({ first: source }, max_size: 2)
      stored = map.instance_variable_get(:@map)[:first]
      source.value = :changed

      assert_equal :copy, map.mode
      assert_instance_of Envelope::Copy, stored
      assert_equal :initial, map[:first].value

      assigned = ModePayload.new(:assigned)

      assert_same assigned, map[:second] = assigned
      assigned.value = :changed

      assert_equal :assigned, map.fetch(:second).value
      assert_equal %i[assigned initial], map.each_value.map(&:value).sort
      assert_equal :initial, map.delete(:first).value
      assert_equal :assigned, map.shift.last.value
      assert_empty map
      assert_raises(ArgumentError) { LRUMap.new(max_size: 1, mode: :invalid) }
    end

    def test_mode_map_preserves_explicit_envelopes
      value = ModePayload.new(:value)
      envelope = Envelope.new(value, mode: :local)
      map = LRUMap.new({ key: envelope }, max_size: 1)

      assert_same envelope, map[:key]
      assert_same envelope, map.fetch(:key)
      assert_same envelope, map.each_value.first
      assert_same envelope, map.shift.last
      assert_same value, envelope.value
    end

    def test_move_mode_does_not_claim_envelopes_while_storing
      assigned = ModePayload.new(:assigned)
      assigned_map = LRUMap.new(max_size: 1, mode: :move)
      assigned_map[:key] = assigned
      assigned_envelope = assigned_map.instance_variable_get(:@map)[:key]

      assert_instance_of Envelope::Move, assigned_envelope
      refute_predicate assigned_envelope, :claimed?

      initial = ModePayload.new(:initial)
      initial_map = LRUMap.new({ key: initial }, max_size: 1, mode: :move)
      initial_envelope = initial_map.instance_variable_get(:@map)[:key]

      assert_instance_of Envelope::Move, initial_envelope
      refute_predicate initial_envelope, :claimed?
    end

    def test_aliased_string_key_is_stable_before_value_preparation
      moved = +"moved"
      move_map = LRUMap.new(max_size: 1, mode: :move)
      move_map[moved] = moved

      assert_equal "moved", move_map["moved"]
      assert_equal "moved", move_map.getkey("moved")
      assert_predicate move_map.getkey("moved"), :frozen?

      copied = +"copied"
      copy_map = LRUMap.new(max_size: 1, mode: :copy)
      copy_map[copied] = copied
      copied.replace("changed")

      expected_value = Internal.native_ractors? ? "copied" : "changed"

      assert_equal expected_value, copy_map["copied"]
      assert_equal "copied", copy_map.getkey("copied")
      assert_nil copy_map["changed"]

      published = +"published"
      publish_map = LRUMap.new(max_size: 1, mode: :make_shareable)
      publish_map[published] = published

      if Internal.native_ractors?
        assert_predicate published, :frozen?
      else
        refute_predicate published, :frozen?
      end

      assert_equal "published", publish_map["published"]
      refute_same published, publish_map.getkey("published")
    end

    def test_bad_key_is_rejected_before_move_preparation
      map = LRUMap.new(max_size: 1, mode: :move)

      key = ModePayload.new(:key)
      value = ModePayload.new(:available)
      if Internal.native_ractors?
        assert_raises(Ractor::IsolationError) { map[key] = value }
        assert_equal :available, value.value
      end

      identity_key = +"mutable"
      identity_value = ModePayload.new(:identity_available)
      identity_map = LRUMap.new(max_size: 1, mode: :move, compare_keys_by_identity: true)
      if Internal.native_ractors?
        assert_raises(Ractor::IsolationError) { identity_map[identity_key] = identity_value }
        assert_equal :identity_available, identity_value.value
      end

      exploding_key = Class.new do
        def hash = raise "hash failed"
      end.new.freeze
      exploding_value = ModePayload.new(:hash_available)
      error = assert_raises(RuntimeError) { map[exploding_key] = exploding_value }

      assert_equal "hash failed", error.message
      assert_equal :hash_available, exploding_value.value
      assert_empty map
      assert_empty identity_map
    end

    def test_mode_map_values_cross_ractors_safely
      map = LRUMap.new(
        { first: ModePayload.new(:first), second: ModePayload.new(:second) },
        max_size: 2,
      )
      worker = Ractor.new(map) { |shared| shared.values.map(&:value) }

      assert_equal %i[first second], ractor_value(worker)
    end

    def test_strict_rejects_unshareable_values
      value = ModePayload.new(:value)
      map = Strict::LRUMap.new(max_size: 1)

      if Internal.native_ractors?
        assert_raises(Ractor::IsolationError) { map[:key] = value }
        assert_raises(Ractor::IsolationError) do
          Strict::LRUMap.new({ key: value }, max_size: 1)
        end
        assert_empty map
      else
        assert_same value, map[:key] = value
        assert_same value, map[:key]
      end
    end

    def test_unshared_and_local_store_mutable_values_directly
      [Unshared::LRUMap, Local::LRUMap].each do |klass|
        value = []
        map = klass.new({ key: value }, max_size: 1)

        assert_same value, map[:key]
        value << :changed

        assert_equal [:changed], map[:key]
      end
    end

    def test_local_scope_preserves_duplicate_initial_access_history
      entries = [[:a, 1], [:b, 2], [:a, 3], [:c, 4]]
      map = Local::LRUMap.new(entries, max_size: 2, scope: :fiber)

      assert_equal({ a: 3, c: 4 }, map.to_h)
      assert_equal [:a, 3], map.shift
      assert_equal 2, map.max_size
      assert_equal [{ a: 3, c: 4 }, [:a, 3]], Fiber.new { [map.to_h, map.shift] }.resume
      assert_raises(ArgumentError) { Local::LRUMap.new(max_size: -1) }
      assert_raises(ArgumentError) do
        Local::LRUMap.new(max_size: 1, compare_by_identity: nil)
      end
    end

    def test_local_capacity_changes_only_the_current_scope
      map = Local::LRUMap.new({ one: 1, two: 2 }, max_size: 2, scope: :fiber)
      map.max_size = 1

      child = Fiber.new do
        before = [map.max_size, map.to_h]
        map.max_size = 3
        map[:three] = 3
        [before, map.max_size, map.to_h]
      end.resume
      fresh = Fiber.new { [map.max_size, map.to_h] }.resume

      assert_equal [[2, { one: 1, two: 2 }], 3, { one: 1, two: 2, three: 3 }], child
      assert_equal [2, { one: 1, two: 2 }], fresh
      assert_equal 1, map.max_size
      assert_equal({ two: 2 }, map.to_h)
    end

    def test_local_ractor_scope_has_independent_contents_history_and_capacity
      map = Local::LRUMap.new({ one: 1, two: 2 }, max_size: 2)
      map[:one]
      map.max_size = 1
      worker = Ractor.new(map) do |local|
        before = [local.max_size, local.to_h]
        local[:three] = 3
        [before, local.max_size, local.to_h]
      end

      assert_equal [[2, { one: 1, two: 2 }], 2, { two: 2, three: 3 }], ractor_value(worker)
      assert_equal 1, map.max_size
      assert_equal({ one: 1 }, map.to_h)
    end

    def test_fetch_uses_original_key_for_fallback_and_error
      key = +"missing"
      map = LRUMap.new(max_size: 1)

      assert_same key, map.fetch(key) { it }
      error = assert_raises(KeyError) { map.fetch(key) }

      assert_same key, error.key
      assert_same map, error.receiver
    end
  end
end
