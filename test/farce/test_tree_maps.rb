# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestTreeMaps < Test
    include Helpers::InternalTestHelpers

    TREE_MAPS = [TreeMap, Strict::TreeMap, Unshared::TreeMap].freeze

    def test_fetch_rejects_missing_and_extra_arguments
      TREE_MAPS.each do |klass|
        map = klass.new

        assert_raises(ArgumentError) { map.fetch }
        assert_raises(ArgumentError) { map.fetch(:key, :default, :extra) }
      end
    end

    def test_public_hierarchy_backends_and_properties
      assert_equal Abstract::TreeMap, TreeMap.superclass
      assert_equal Abstract::TreeMap, Strict::TreeMap.superclass
      assert_equal Abstract::TreeMap, Unshared::TreeMap.superclass
      assert_instance_of Internal::StrictTreeMap, TreeMap.new.instance_variable_get(:@map)
      assert_instance_of Internal::StrictTreeMap, Strict::TreeMap.new.instance_variable_get(:@map)
      assert_instance_of Internal::TreeMap, Unshared::TreeMap.new.instance_variable_get(:@map)

      TREE_MAPS.each do |klass|
        map = klass.new

        assert_predicate map, :shareable_keys?
        refute_predicate map, :compare_keys_by_identity?
        refute_predicate map, :compare_values_by_identity?
        refute_predicate map, :weak_keys?
        refute_predicate map, :weak_values?
      end

      assert_predicate TreeMap.new, :shareable_values?
      assert_predicate Strict::TreeMap.new, :shareable_values?
      refute_predicate Unshared::TreeMap.new, :shareable_values?
      assert_predicate TreeMap.new, :ractor_shareable?
      assert_predicate Strict::TreeMap.new, :ractor_shareable?
      refute_predicate Unshared::TreeMap.new, :ractor_shareable?
    end

    def test_native_ractor_shareability
      return unless Internal.native_ractors?

      assert Ractor.shareable?(TreeMap.new)
      assert Ractor.shareable?(Strict::TreeMap.new)
      refute Ractor.shareable?(Unshared::TreeMap.new)
    end

    def test_ordered_interface_and_public_fetch_receiver
      TREE_MAPS.each do |klass|
        map = klass.new([[3, :three], [1, :one], [2, nil]])

        assert_equal [[1, :one], [2, nil], [3, :three]], map.to_a
        assert_equal 1, map.first_key
        assert_equal 3, map.last_key
        assert_equal [1, 2, 3], map.keys
        assert_equal [:one, nil, :three], map.values
        assert_nil map.fetch(2)
        assert_equal :fallback, map.fetch(4, :fallback)
        assert_equal :missing, map.fetch(4) { |key| key == 4 ? :missing : :unexpected }

        error = assert_raises(KeyError) { map.fetch(4) }

        assert_same map, error.receiver
        assert_equal 4, error.key
        assert_equal [1, :one], map.shift
        assert_equal [3, :three], map.pop
        assert_equal [2, nil], map.pop
        assert_nil map.shift
        assert_same map, map.clear
      end
    end

    def test_iteration_uses_a_snapshot_and_returns_the_public_map
      TREE_MAPS.each do |klass|
        map = klass.new(3 => :three, 1 => :one)
        visited = []

        result = map.each do |key, value|
          visited << [key, value]
          map[2] = :two if key == 1
        end

        assert_same map, result
        assert_equal [[1, :one], [3, :three]], visited
        assert_equal [[1, :one], [2, :two], [3, :three]], map.each_pair.to_a
        assert_equal [1, 2, 3], map.each_key.to_a
        assert_equal %i[one two three], map.each_value.to_a
      end
    end

    def test_mutable_strings_are_stored_as_canonical_keys
      TREE_MAPS.each do |klass|
        original = +"middle"
        canonical = -original
        map = klass.new(original => :value)
        stored = map.getkey(+"middle")

        original.replace("changed")

        assert_same canonical, stored if RUBY_ENGINE == "ruby"

        assert_predicate stored, :frozen?
        assert_equal :value, map["middle"]
        assert_nil map["changed"]
      end
    end

    def test_invalid_hash_conversion_is_rejected
      source = Object.new
      source.define_singleton_method(:to_hash) { nil }

      TREE_MAPS.each do |klass|
        assert_raises(TypeError) { klass.new(source) }
      end
    end

    def test_mode_map_copies_and_unwraps_values
      source = ModePayload.new(:initial)
      map = TreeMap.new({ 2 => source })
      initial_envelope = map.instance_variable_get(:@map)[2]

      source.value = :changed

      assert_equal :copy, map.mode
      assert_instance_of Envelope::Copy, initial_envelope
      assert_equal :initial, map[2].value

      assigned = ModePayload.new(:assigned)

      assert_same assigned, map[1] = assigned
      assigned.value = :changed

      assert_equal :assigned, map.fetch(1).value
      assert_equal %i[assigned initial], map.each_value.map(&:value)
      assert_equal :assigned, map.shift.last.value
      assert_equal :initial, map.pop.last.value
      assert_nil map.pop
      assert_raises(ArgumentError) { TreeMap.new(mode: :invalid) }
    end

    def test_mode_map_preserves_explicit_envelopes
      value = ModePayload.new(:value)
      envelope = Envelope.new(value, mode: :local)
      map = TreeMap.new(1 => envelope)

      assert_same envelope, map[1]
      assert_same envelope, map.fetch(1)
      assert_same envelope, map.each_value.first
      assert_same envelope, map.delete(1)
      assert_same value, envelope.value
    end

    def test_mode_map_does_not_claim_move_envelopes_while_storing
      assigned = ModePayload.new(:assigned)
      assigned_map = TreeMap.new(mode: :move)

      assigned_map[1] = assigned
      assigned_envelope = assigned_map.instance_variable_get(:@map)[1]

      assert_instance_of Envelope::Move, assigned_envelope
      refute_predicate assigned_envelope, :claimed?

      initial = ModePayload.new(:initial)
      initial_map = TreeMap.new({ 1 => initial }, mode: :move)
      initial_envelope = initial_map.instance_variable_get(:@map)[1]

      assert_instance_of Envelope::Move, initial_envelope
      refute_predicate initial_envelope, :claimed?
    end

    def test_mode_map_rejects_a_bad_key_before_moving_the_value
      key = ModePayload.new(:key)
      value = ModePayload.new(:available)
      map = TreeMap.new(mode: :move)

      assert_raises(Ractor::IsolationError) { map[key] = value }
      assert_equal :available, value.value
      assert_empty map
    end

    def test_mode_map_transfers_copied_values_between_ractors
      return unless Internal.native_ractors?

      map = TreeMap.new(
        2 => ModePayload.new(:second),
        1 => ModePayload.new(:first),
      )
      worker = Ractor.new(map) { |shared| shared.values.map(&:value) }

      assert_equal %i[first second], ractor_value(worker)
    end

    def test_strict_tree_map_rejects_unshareable_values
      value = ModePayload.new(:value)
      map = Strict::TreeMap.new

      assert_raises(Ractor::IsolationError) { map[1] = value }
      assert_raises(Ractor::IsolationError) { Strict::TreeMap.new(1 => value) }
      assert_empty map
    end

    def test_unshared_tree_map_stores_mutable_values_directly
      value = []
      map = Unshared::TreeMap.new(1 => value)

      assert_same value, map[1]
      value << :changed

      assert_equal [:changed], map[1]
    end
  end
end
