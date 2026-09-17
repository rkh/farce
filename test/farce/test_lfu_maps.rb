# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestLFUMaps < Test
    include Helpers::InternalTestHelpers

    DIRECT_MAPS = [LFUMap, Strict::LFUMap, Unshared::LFUMap, Unsafe::LFUMap].freeze

    def test_abstract_factory_errors
      assert_raises(NoMethodError) { Abstract::LFUMap.new(max_size: 1) }

      subclass = Class.new(Abstract::LFUMap)
      error = assert_raises(RuntimeError) { subclass.new(max_size: 1) }

      assert_match(/subclass failed to implement #new_bounded_map/, error.message)
    end

    def test_public_hierarchy_backends_and_properties
      assert_equal Abstract::LFUMap, LFUMap.superclass
      assert_equal Abstract::LFUMap, Strict::LFUMap.superclass
      assert_equal Abstract::LFUMap, Unshared::LFUMap.superclass
      assert_equal Abstract::LFUMap, Unsafe::LFUMap.superclass
      assert_equal Abstract::LFUMap, Local::LFUMap.superclass
      assert_instance_of Internal::StrictLFUMap, LFUMap.new(max_size: 1).instance_variable_get(:@map)
      assert_instance_of Internal::StrictLFUMap, Strict::LFUMap.new(max_size: 1).instance_variable_get(:@map)
      assert_instance_of Internal::LFUMap, Unshared::LFUMap.new(max_size: 1).instance_variable_get(:@map)
      assert_instance_of Internal::LFUMap, Unsafe::LFUMap.new(max_size: 1).instance_variable_get(:@map)

      local = Local::LFUMap.new(max_size: 1)

      assert_instance_of Internal::LFUMap, Internal::Storage[local].map
      assert_predicate LFUMap.new(max_size: 1), :ractor_shareable?
      assert_predicate Strict::LFUMap.new(max_size: 1), :ractor_shareable?
      refute_predicate Unshared::LFUMap.new(max_size: 1), :ractor_shareable?
      assert_predicate local, :ractor_shareable?
      assert Ractor.shareable?(LFUMap.new(max_size: 1))
      assert Ractor.shareable?(local)
    end

    def test_public_protocol_and_lfu_policy
      DIRECT_MAPS.each do |klass|
        map = klass.new([[nil, false], [false, nil], [:hot, 3]], max_size: 3)

        refute map[nil]
        assert_nil map[false]
        4.times { map[:hot] }
        2.times { map[false] }

        map[:new] = 4

        refute map.key?(nil)
        assert map.key?(false)
        assert map.key?(:hot)
        assert map.key?(:new)
        assert_equal [:new, 4], map.shift
        assert_equal 1, map.prune(to: 1)
        assert_equal({ hot: 3 }, map.to_h)
        assert_same map, map.clear
        assert_empty map
      end
    end

    def test_mode_copy_explicit_envelope_and_move
      source = ModePayload.new(:source)
      map = LFUMap.new({ key: source }, max_size: 2)
      stored = map.instance_variable_get(:@map)[:key]
      source.value = :changed

      assert_equal :copy, map.mode
      assert_instance_of Envelope::Copy, stored
      assert_equal :source, map[:key].value

      explicit_value = ModePayload.new(:explicit)
      envelope = Envelope.new(explicit_value, mode: :local)
      map[:explicit] = envelope

      assert_same envelope, map[:explicit]
      assert_same envelope, map.delete(:explicit)

      moved = ModePayload.new(:moved)
      move_map = LFUMap.new(max_size: 1, mode: :move)
      move_map[:key] = moved
      move_envelope = move_map.instance_variable_get(:@map)[:key]

      assert_instance_of Envelope::Move, move_envelope
      refute_predicate move_envelope, :claimed?
    end

    def test_aliased_string_key_is_prepared_before_move
      value = +"same"
      map = LFUMap.new(max_size: 1, mode: :move)
      map[value] = value

      assert_equal "same", map["same"]
      assert_equal "same", map.getkey("same")
      assert_predicate map.getkey("same"), :frozen?
    end

    def test_bad_key_is_rejected_before_move
      key = ModePayload.new(:key)
      value = ModePayload.new(:available)
      map = LFUMap.new(max_size: 1, mode: :move)

      assert_raises(Ractor::IsolationError) { map[key] = value }
      assert_equal :available, value.value
      assert_empty map
    end

    def test_mode_values_cross_ractors
      map = LFUMap.new(
        { first: ModePayload.new(:first), second: ModePayload.new(:second) },
        max_size: 2,
      )
      worker = Ractor.new(map) { |shared| shared.values.map(&:value).sort }

      assert_equal %i[first second], ractor_value(worker)
    end

    def test_strict_rejects_and_unshared_retains_mutable_values
      value = ModePayload.new(:value)
      strict = Strict::LFUMap.new(max_size: 1)

      if Internal.native_ractors?
        assert_raises(Ractor::IsolationError) { strict[:key] = value }
        assert_empty strict
      else
        assert_same value, strict[:key] = value
        assert_same value, strict[:key]
      end

      mutable = []
      unshared = Unshared::LFUMap.new({ key: mutable }, max_size: 1)

      assert_same mutable, unshared[:key]
      mutable << :changed

      assert_equal [:changed], unshared[:key]
    end

    def test_local_replays_duplicate_history_in_each_scope
      entries = [[:a, 1], [:b, 2], [:a, 3], [:c, 4]]
      map = Local::LFUMap.new(entries, max_size: 2, scope: :fiber)

      assert_equal({ a: 3, c: 4 }, map.to_h)
      assert_equal [:c, 4], map.shift
      assert_equal [{ a: 3, c: 4 }, [:c, 4]], Fiber.new { [map.to_h, map.shift] }.resume
    end

    def test_local_capacity_and_history_are_scope_local
      map = Local::LFUMap.new({ one: 1, two: 2 }, max_size: 2, scope: :fiber)
      map[:one]
      map.max_size = 1

      child = Fiber.new do
        before = [map.max_size, map.to_h]
        2.times { map[:two] }
        map[:three] = 3
        [before, map.max_size, map.to_h, map.shift]
      end.resume
      fresh = Fiber.new { [map.max_size, map.to_h] }.resume

      assert_equal [[2, { one: 1, two: 2 }], 2, { two: 2, three: 3 }, [:three, 3]], child
      assert_equal [2, { one: 1, two: 2 }], fresh
      assert_equal 1, map.max_size
      assert_equal({ one: 1 }, map.to_h)
    end

    def test_comparison_flags_delegate
      [*DIRECT_MAPS, Local::LFUMap].each do |klass|
        map = klass.new(max_size: 1, compare_by_identity: true)

        assert_predicate map, :compare_keys_by_identity?
        assert_predicate map, :compare_values_by_identity?
      end
    end
  end
end
