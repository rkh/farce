# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestMapMutation < Test
    MAPS = [Map, Strict::Map, Unshared::Map, Local::Map,
            WeakKeyMap, Strict::WeakKeyMap, Strict::WeakValueMap, Strict::WeakMap,
            Unshared::WeakKeyMap, Unshared::WeakValueMap, Unshared::WeakMap,
            Local::WeakKeyMap, Local::WeakValueMap, Local::WeakMap].freeze

    def test_filters_and_return_values
      MAPS.each do |type|
        map = type.new({ 1 => nil, 2 => false, 3 => :value })

        assert_same(map, map.delete_if { |key, _| key == 3 })
        assert_equal({ 1 => nil, 2 => false }, map.to_h)
        assert_nil(map.reject! { false })
        assert_same(map, map.reject! { |_, value| nil.equal?(value) })
        assert_equal({ 2 => false }, map.to_h)
        assert_nil(map.select! { true })
        assert_same(map, map.keep_if { false })
        assert_empty map
        map[1] = :value

        assert_same(map, map.filter! { false })
        assert_empty map
      end
    end

    def test_transform_and_merge_preserve_nil_presence
      MAPS.each do |type|
        map = type.new({ 1 => nil }, normalize_keys: :succ)
        calls = []

        result = map.merge!({ 1 => 3, 2 => 4 }) do |key, old, new|
          calls << [key, old, new]
          5
        end

        assert_same map, result
        assert_equal [[1, nil, 3]], calls
        assert_equal({ 2 => 5, 3 => 4 }, map.to_h)
        assert_same(map, map.transform_values! { it * 2 })
        assert_equal({ 2 => 10, 3 => 8 }, map.to_h)
        assert_same(map, map.delete_if { |key, _| key == 2 })
        assert_equal({ 3 => 8 }, map.to_h)
        assert_same map, map.merge!
      end
    end

    def test_enumerators_and_exceptions_release_updates
      MAPS.each do |type|
        map = type.new({ 1 => :old })
        %i[delete_if reject! keep_if select! filter! transform_values!].each do |method|
          enumerator = map.public_send(method)

          assert_instance_of Enumerator, enumerator
          assert_equal 1, enumerator.size
          assert_raises(RuntimeError) { map.public_send(method) { raise "failure" } }
          assert_equal :old, map[1]
        end
        map[1] = :new

        assert_equal :new, map[1]
      end
    end

    def test_internal_modify_distinguishes_missing_nil_and_control_values
      MAPS.each do |type|
        backend = type.new.__send__(:internal_map)

        changed = backend.modify(1) do |present, value|
          assert_equal [false, nil], [present, value]
          Internal::MAP_KEEP
        end

        refute changed
        refute backend.key?(1)
        assert backend.modify(1) { nil }
        changed = backend.modify(1) do |present, value|
          assert_equal [true, nil], [present, value]
          Internal::MAP_KEEP
        end

        refute changed
        assert backend.key?(1)
        assert backend.modify(1) { :delete }
        assert_equal :delete, backend[1]
        assert backend.modify(1) { Internal::MAP_DELETE }
        refute backend.key?(1)
        refute backend.modify(1) { Internal::MAP_DELETE }
        assert_raises(RuntimeError) { backend.modify(1) { raise "failure" } }
        backend[1] = :usable

        assert_equal :usable, backend[1]
      end
    end

    def test_keep_does_not_rewrap_move_values
      map = Map.new({ 1 => [] }, mode: :move)
      backend = map.__send__(:internal_map)
      stored = backend[1]

      assert_nil(map.reject! { false })
      assert_same stored, backend[1]
    end

    def test_merge_coercion_and_multiple_inputs
      map = Map.new({ a: 1 })
      input = Object.new
      def input.to_hash = { a: 2 }

      assert_same map, map.merge!(input, Unshared::Map.new({ b: 3 }))
      assert_equal({ a: 2, b: 3 }, map.to_h)
      assert_raises(TypeError) { map.merge!([[:c, 4]]) }
    end

    def test_decision_reserves_the_key_until_commit
      [Map, Strict::Map, Unshared::Map, WeakKeyMap, Strict::WeakValueMap, Unshared::WeakMap].each do |type|
        map = type.new({ 1 => :old })
        entered = ::Queue.new
        release = ::Queue.new
        worker = Thread.new do
          map.delete_if do |_, value|
            entered << value
            release.pop
            true
          end
        end
        begin
          assert_equal :old, entered.pop
          assert_equal :busy, map.store(1, :replacement, timeout: 0) { :busy }
        ensure
          release << true
          worker.value
        end

        refute map.key?(1)
        map[1] = :replacement

        assert_equal :replacement, map[1]
      end
    end

    def test_clear_invalidates_in_flight_decisions
      [Map, Strict::Map, Unshared::Map].each do |type|
        map = type.new({ 1 => :old })
        result = map.reject! do
          map.clear
          map[1] = :replacement
          true
        end

        assert_nil result
        assert_equal :replacement, map[1]
        map.transform_values! do
          map.clear
          :stale
        end

        assert_empty map
      end
    end

    def test_transform_skips_keys_deleted_after_iteration_starts
      [Map, Strict::Map, Unshared::Map].each do |type|
        map = type.new({ 1 => 1, 2 => 2 })
        first, second = map.keys
        visited = []
        map.transform_values! do |value|
          visited << value
          map.delete(second)
          value + 10
        end

        assert_equal [first], visited
        assert_equal({ first => first + 10 }, map.to_h)
      end
    end

    def test_local_mutations_only_change_the_current_scope
      map = Local::Map.new({ 1 => :initial }, scope: :fiber)
      map.transform_values! { :changed }

      assert_equal :changed, map[1]
      assert_equal :initial, Fiber.new { map[1] }.resume
    end

    def test_methods_are_not_added_to_tree_bounded_or_lease_maps
      [TreeMap, LRUMap, LFUMap, LeaseMap].each do |type|
        %i[delete_if reject! keep_if select! filter! transform_values! merge!].each do |method|
          refute_includes type.instance_methods, method
        end
      end
    end
  end
end
