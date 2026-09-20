# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestDuplicableMap < Test
    MAPS = [Map, Strict::Map, Unshared::Map, Local::Map,
            WeakKeyMap, Strict::WeakKeyMap, Strict::WeakValueMap, Strict::WeakMap,
            Unshared::WeakKeyMap, Unshared::WeakValueMap, Unshared::WeakMap,
            Local::WeakKeyMap, Local::WeakValueMap, Local::WeakMap,
            TreeMap, Strict::TreeMap, Unshared::TreeMap, Unsafe::TreeMap, Local::TreeMap,
            LRUMap, Strict::LRUMap, Unshared::LRUMap, Unsafe::LRUMap, Local::LRUMap,
            LFUMap, Strict::LFUMap, Unshared::LFUMap, Unsafe::LFUMap, Local::LFUMap].freeze

    def test_operations_return_independent_maps_of_the_same_kind
      MAPS.each do |type|
        source = new_map(type, { 1 => :a, 2 => nil, 3 => false })
        results = {
          source.slice(3, 1, 9)            => { 1 => :a, 3 => false },
          source.except(1, 9)              => { 2 => nil, 3 => false },
          source.compact                   => { 1 => :a, 3 => false },
          source.transform_keys(&:-@)      => { -1 => :a, -2 => nil, -3 => false },
          source.transform_values { :new } => { 1 => :new, 2 => :new, 3 => :new },
        }
        results.each do |copy, expected|
          assert_instance_of type, copy
          assert_equal expected, copy.to_h, type.name
          assert Ractor.shareable?(copy) if source.is_a?(Shareable)
          assert_equal source.max_size, copy.max_size if source.is_a?(Abstract::BoundedMap)
          copy.clear

          assert_equal({ 1 => :a, 2 => nil, 3 => false }, source.to_h)
        end
        assert_empty source.slice
        assert_equal source.to_h, source.except.to_h
      end
    end

    def test_filters_return_independent_maps_and_enumerators
      MAPS.each do |type|
        source = new_map(type, { 1 => nil, 2 => false, 3 => :keep }, normalize_keys: :succ)
        %i[select filter reject].each do |method|
          predicate = ->(_key, value) { method == :reject ? nil.equal?(value) : !nil.equal?(value) }
          copy = source.public_send(method, &predicate)

          assert_instance_of type, copy
          assert_equal({ 3 => false, 4 => :keep }, copy.to_h)
          assert_equal :keep, copy[3]
          assert_equal source.max_size, copy.max_size if source.is_a?(Abstract::BoundedMap)
          assert Ractor.shareable?(copy) if source.is_a?(Shareable)
          enumerator = source.public_send(method)

          assert_instance_of Enumerator, enumerator
          assert_equal 3, enumerator.size
          assert_equal copy.to_h, enumerator.each(&predicate).to_h
          copy.clear

          assert_equal({ 2 => nil, 3 => false, 4 => :keep }, source.to_h)
          assert_raises(RuntimeError) { source.public_send(method) { raise "failure" } }
          assert_equal 3, source.size
        end
      end
    end

    def test_filter_blocks_receive_public_values_without_moving_the_source
      %i[copy move].each do |mode|
        %i[select filter reject].each do |method|
          source = Map.new({ a: [1], b: [2] }, mode:)
          seen = []
          copy = source.public_send(method) do |key, value|
            seen << [key, value]
            value == (method == :reject ? [2] : [1])
          end

          assert_equal({ a: [1], b: [2] }, seen.to_h)
          assert_equal({ a: [1] }, copy.to_h)
          assert_equal mode, copy.mode
          assert_equal({ a: [1], b: [2] }, source.to_h)
        end
      end
    end

    def test_value_lookup_uses_equality_and_preserves_nil_and_false
      MAPS.each do |type|
        value = String.new("value").freeze
        equal_value = String.new("value").freeze
        map = new_map(type, { 1 => value, 2 => nil, 3 => false }, normalize_keys: :succ)

        assert map.value?(equal_value)
        assert map.has_value?(equal_value) # rubocop:disable Style/PreferredHashMethods
        assert_equal 2, map.key(equal_value)
        assert_equal [2, value], map.rassoc(equal_value)
        assert map.value?(nil)
        assert map.value?(false)
        assert_equal 3, map.key(nil)
        assert_equal [4, false], map.rassoc(false)
        refute map.value?(:missing)
        assert_nil map.key(:missing)
        assert_nil map.rassoc(:missing)
      end
      map = Unshared::Map.new({ nil => :value })

      assert map.value?(:value)
      assert_nil map.key(:value)
      assert_equal [nil, :value], map.rassoc(:value)
    end

    def test_value_lookup_honors_identity_comparison
      MAPS.reject { it < Abstract::TreeMap }.each do |type|
        value = String.new("value").freeze
        equal_value = String.new("value").freeze
        map = new_map(type, { 1 => value }, compare_values_by_identity: true)

        assert map.value?(value)
        assert map.has_value?(value) # rubocop:disable Style/PreferredHashMethods
        assert_equal 1, map.key(value)
        assert_equal [1, value], map.rassoc(value)
        refute map.value?(equal_value)
        refute map.has_value?(equal_value) # rubocop:disable Style/PreferredHashMethods
        assert_nil map.key(equal_value)
        assert_nil map.rassoc(equal_value)
      end
    end

    def test_value_lookup_unwraps_values
      %i[copy move].each do |mode|
        map = Map.new({ a: [1] }, mode:)

        assert map.value?([1])
        assert_equal :a, map.key([1])
        assert_equal [:a, [1]], map.rassoc([1])
        assert_equal [1], map[:a]
      end
    end

    def test_length_tracks_size
      MAPS.each do |type|
        map = new_map(type, { 1 => false })

        assert_equal 1, map.length
        map.clear

        assert_equal 0, map.length
      end
    end

    def test_normalization_is_applied_once_to_external_and_transformed_keys
      MAPS.each do |type|
        source = new_map(type, { 1 => :a, 2 => nil }, normalize_keys: :succ)

        assert_equal({ 2 => :a }, source.slice(1).to_h)
        assert_equal({ 3 => nil }, source.except(1).to_h)
        assert_equal({ 2 => :a }, source.compact.to_h)
        assert_equal({ 2 => :new, 3 => :new }, source.transform_values { :new }.to_h)
        assert_equal({ 13 => :a, 14 => nil }, source.transform_keys { |key| key + 10 }.to_h)
        assert_equal({ 11 => :a, 3 => nil }, source.transform_keys(2 => 10).to_h)
        assert_equal :a, source.slice(1)[1]
      end
    end

    def test_transform_keys_mapping_block_and_collisions
      source = Unshared::Map.new({ a: 1, b: 2, c: 3 })

      assert_equal({ nil => 1, b: 2, c: 3 }, source.transform_keys(a: nil).to_h)
      assert_equal({ z: 1, "b" => 2, "c" => 3 }, source.transform_keys({ a: :z }, &:to_s).to_h)
      assert_equal 1, source.transform_keys { :same }.size
      assert_equal 3, source.size
      assert_raises(TypeError) { source.transform_keys(nil) }
      mapping = Object.new
      def mapping.to_hash = { a: :z }

      assert_equal({ z: 1, b: 2, c: 3 }, source.transform_keys(mapping).to_h)
    end

    def test_transform_enumerators
      source = Unshared::Map.new({ a: 1 })

      assert_instance_of Enumerator, source.transform_keys
      assert_equal 1, source.transform_keys.size
      assert_equal({ "a" => 1 }, source.transform_keys.each(&:to_s).to_h)
      assert_equal 1, source.transform_values.size
      assert_equal({ a: 2 }, source.transform_values.each { it + 1 }.to_h)
    end

    def test_invert_returns_same_kind_and_preserves_settings
      MAPS.each do |type|
        source = new_map(type, { 1 => 10, 2 => 20 }, normalize_keys: :succ)
        copy = source.invert

        assert_instance_of type, copy
        assert_equal({ 11 => 2, 21 => 3 }, copy.to_h, type.name)
        assert_equal source.max_size, copy.max_size if source.is_a?(Abstract::BoundedMap)
        assert Ractor.shareable?(copy) if Ractor.shareable?(source)
        copy.clear

        assert_equal({ 2 => 10, 3 => 20 }, source.to_h)
      end
      source = Unshared::TreeMap.new({ 1 => 10, 2 => 10 })

      assert_equal({ 10 => 2 }, source.invert.to_h)
    end

    def test_invert_rejects_unshareable_keys_without_changing_source
      types = [Map, TreeMap]
      types += [LRUMap, LFUMap] if Internal.native_ractors?
      types.each do |type|
        value = Unshared::Map.new
        source = new_map(type, { 1 => value }, mode: :local)

        assert_raises(Ractor::IsolationError) { source.invert }
        assert_same value, source[1]
      end
    end

    def test_invert_allows_unshareable_keys_where_the_map_allows_them
      [Unshared::Map, Unshared::LRUMap, Unshared::LFUMap, Unsafe::LRUMap, Unsafe::LFUMap].each do |type|
        value = Unshared::Map.new
        source = new_map(type, { 1 => value })
        copy = source.invert

        assert_instance_of type, copy
        assert_equal 1, copy[value]
        assert_same value, copy.keys.first
        assert_same value, source[1]
      end
    end

    def test_invert_accepts_mutable_string_keys_using_normal_assignment_rules
      source = Map.new({ 1 => String.new("key") }, mode: :local)
      copy = source.invert

      assert_equal 1, copy["key"]
      assert_predicate copy.keys.first, :frozen?
      refute_predicate source[1], :frozen?
    end

    def test_to_proc_performs_live_lookups
      MAPS.each do |type|
        source = new_map(type, { 1 => :first }, normalize_keys: :succ)
        lookup = source.to_proc

        assert_predicate lookup, :lambda?
        assert_equal 1, lookup.arity
        assert_equal [:first, nil], [1, 9].map(&source)
        source[1] = :changed

        assert_equal :changed, lookup.call(1)
        assert_raises(ArgumentError) { lookup.call }
        assert_raises(ArgumentError) { lookup.call(1, 2) }
        assert Ractor.shareable?(lookup) if Ractor.shareable?(source)
      end
      lookup = Map.new({ answer: 42 }).to_proc
      ractor = Ractor.new(lookup) { |callback| callback.call(:answer) }

      assert_equal 42, ractor.respond_to?(:value) ? ractor.value : ractor.take
    end

    def test_merge_returns_same_kind_and_normalizes_incoming_keys_once
      MAPS.each do |type|
        source = new_map(type, { 1 => 10, 2 => nil }, normalize_keys: :succ)
        incoming = Unshared::Map.new({ 3 => 30 })
        copy = source.merge({ 1 => 20, 2 => 25 }, incoming) { |key, old, value| key + (old || 0) + value }

        assert_instance_of type, copy
        assert_equal({ 2 => 32, 3 => 28, 4 => 30 }, copy.to_h, type.name)
        assert_equal({ 2 => 10, 3 => nil }, source.to_h)
        assert_equal({ 3 => 30 }, incoming.to_h)
        assert_equal source.to_h, source.merge.to_h
        refute_same source, source.merge
      end
    end

    def test_merge_coercion_precedence_and_failures
      source = Unshared::Map.new({ a: 1 })
      incoming = Object.new
      def incoming.to_hash = { a: 2, b: 3 }

      assert_equal({ a: 4, b: 3 }, source.merge(incoming, { a: 4 }).to_h)
      assert_raises(TypeError) { source.merge([[:b, 2]]) }
      assert_raises(TypeError) { source.merge(nil) }
      assert_raises(RuntimeError) { source.merge({ a: 2 }) { raise "failure" } }
      assert_equal({ a: 1 }, source.to_h)
    end

    def test_merge_does_not_move_values_out_of_source_or_inputs
      [Map, TreeMap, LRUMap, LFUMap].each do |type|
        source = new_map(type, { 1 => [1] }, mode: :move)
        incoming = { 1 => [2], 2 => [3] }
        copy = source.merge(incoming) { |_, old, _| old }

        assert_equal [1], source[1]
        assert_equal [1], copy[1]
        assert_equal [3], copy[2]
        assert_equal({ 1 => [2], 2 => [3] }, incoming)
      end
    end

    def test_flatten_matches_hash_depth_behavior
      source = Unshared::Map.new({ a: [1, [2]], b: 3 })

      assert_equal source.to_h.flatten, source.flatten
      [0, 1, 2, 3, -1].each do |depth|
        assert_equal source.to_h.flatten(depth), source.flatten(depth)
      end
      assert_raises(TypeError) { source.flatten(nil) }
      depth = Object.new
      def depth.to_int = 2

      assert_equal source.to_h.flatten(2), source.flatten(depth)
    end

    def test_value_conversion_hooks_are_protected
      ([Abstract::Map] + MAPS).each do |type|
        %i[wrap_value unwrap_value].each do |name|
          assert_includes type.protected_instance_methods, name, type.name
          refute_includes type.public_instance_methods, name, type.name
        end
      end
      map = Abstract::Map.allocate
      value = Object.new

      assert_same value, map.__send__(:wrap_value, value)
      assert_same value, map.__send__(:unwrap_value, value)
    end

    def test_transform_keys_starts_empty_and_preserves_wrapper_state
      type = Class.new(Unshared::Map) do
        attr_reader :marker

        def initialize(...)
          @marker = Object.new
          super
        end

        private def copy_map_backend(source, empty: false)
          raise "copied populated storage" unless empty
          super
        end
      end
      source = type.new({ 1 => :first, 2 => :second })
      copy = source.transform_keys { 3 - it }

      assert_same source.marker, copy.marker
      assert_equal({ 2 => :first, 1 => :second }, copy.to_h)
      assert_equal({ 1 => :first, 2 => :second }, source.to_h)
    end

    def test_transform_keys_can_clear_source_during_iteration
      MAPS.each do |type|
        source = new_map(type, { 1 => :first, 2 => :second })
        copy = source.transform_keys do |key|
          source.clear
          3 - key
        end

        assert_equal({ 2 => :first, 1 => :second }, copy.to_h, type.name)
        assert_empty source
      end
    end

    def test_identity_keys_are_preserved
      source = Unshared::Map.new(compare_by_identity: true)
      first = String.new("key")
      second = String.new("key")
      source[first] = :first
      source[second] = :second

      assert_equal [:first], source.slice(first).values
      assert_equal [:second], source.except(first).values
      assert_empty source.slice(String.new("key"))
      assert_predicate source.compact, :compare_keys_by_identity?
      assert_predicate source.transform_values { it }, :compare_values_by_identity?
    end

    def test_key_only_operations_do_not_claim_move_envelopes
      [Map, TreeMap, LRUMap, LFUMap].each do |type|
        source = new_map(type, { 1 => [] }, mode: :move)
        envelope = source.instance_variable_get(:@map).each.to_a.first.last
        [source.slice(1), source.except(2), source.compact, source.transform_keys { 2 }].each do |copy|
          assert_equal :move, copy.mode
          assert_same envelope, copy.instance_variable_get(:@map).each.to_a.first.last
          refute_predicate envelope, :claimed? if envelope.is_a?(Envelope)
        end
      end
    end

    def test_transform_values_does_not_move_existing_payloads_out_of_source
      [Map, TreeMap, LRUMap, LFUMap].each do |type|
        source = new_map(type, { 1 => [1] }, mode: :move)
        copy = source.transform_values { it }

        assert_equal :move, copy.mode
        assert_equal [1], source[1]
        assert_equal [1], copy[1]
        refute_same source[1], copy[1] unless Ractor.shareable?(source[1])
      end
    end

    def test_local_operations_follow_dup_scope_behavior
      source = Local::Map.new({ 1 => :initial }, scope: :fiber)
      source[1] = :current
      copy = source.transform_values { :changed }

      assert_equal :fiber, copy.scope
      assert_equal :changed, copy[1]
      assert_equal :initial, Fiber.new { copy[1] }.resume
      assert_equal :current, source[1]
    end

    def test_empty_copies_preserve_local_defaults_and_current_capacity
      MAPS.select { it.name.start_with?("Farce::Local::") }.each do |type|
        source = new_map(type, { 1 => :initial }, scope: :fiber, normalize_keys: :succ)
        source[1] = :current
        source.max_size = 2 if source.is_a?(Abstract::BoundedMap)
        copy = source.transform_keys { 10 }

        assert_equal :fiber, copy.scope
        assert_equal({ 11 => :current }, copy.to_h)
        assert_equal({ 2 => :initial }, Fiber.new { copy.to_h }.resume)
        assert_equal :current, source[1]
        next unless source.is_a?(Abstract::BoundedMap)

        assert_equal 2, copy.max_size
        assert_equal 5, Fiber.new { copy.max_size }.resume
      end
    end

    def test_filtering_preserves_bounded_history_without_accessing_the_source
      [LRUMap, LFUMap].each do |type|
        source = type.new({ 1 => :a, 2 => :b, 3 => :c }, max_size: 3)
        4.times { source[1] }
        2.times { source[2] }
        copies = [source.slice(1, 2), source.except(3), source.compact, source.merge]
        copies.each do |copy|
          copy[4] = :d
          copy[5] = :e

          assert_equal type == LRUMap ? [2, 4, 5] : [1, 2, 5], copy.keys.sort
        end
        source[4] = :d

        assert_equal [1, 2, 4], source.keys.sort
      end
    end

    def test_blocks_can_modify_the_source_without_changing_iteration
      source = Unshared::Map.new({ 1 => 10, 2 => 20 })
      copy = source.transform_values do |value|
        source.clear
        value + 1
      end

      assert_equal({ 1 => 11, 2 => 21 }, copy.to_h)
      assert_empty source
    end

    def test_strict_results_keep_validation_and_exceptions_leave_source_unchanged
      types = [Strict::Map, Strict::TreeMap]
      types += [Strict::LRUMap, Strict::LFUMap] if Internal.native_ractors?
      types.each do |type|
        source = new_map(type, { 1 => :value })
        unshareable = Unshared::Map.new

        assert_raises(Ractor::IsolationError) { source.transform_values { unshareable } }
        assert_raises(Ractor::IsolationError) { source.transform_keys { unshareable } }
        assert_raises(RuntimeError) { source.transform_values { raise "block failure" } }
        assert_equal({ 1 => :value }, source.to_h)
      end
    end

    def test_slice_and_except_use_tree_comparison_and_accept_nil_hash_keys
      source = Unshared::TreeMap.new({ 1 => :value })

      assert_equal({ 1 => :value }, source.slice(1.0).to_h)
      assert_empty source.except(1.0)
      source = Unshared::Map.new({ nil => false, :other => nil })

      assert_equal({ nil => false }, source.slice(nil).to_h)
      assert_equal({ other: nil }, source.except(nil).to_h)
      assert_equal({ nil => false }, source.compact.to_h)
    end

    def test_to_h_accepts_a_block_and_to_s_uses_inspect
      MAPS.each do |type|
        source = new_map(type, { 1 => 2 })

        assert_equal({ 2 => 3 }, source.to_h { |key, value| [key + 1, value + 1] })
        assert_raises(TypeError) { source.to_h { :invalid } }
        assert_equal source.inspect, source.to_s
        assert_equal({ 1 => 2 }, Hash.try_convert(source))
        assert_equal({ 1 => 2 }, {}.merge(source))
        assert_equal({ 1 => 2 }, { **source })
        refute_predicate source.to_h, :compare_by_identity?
      end
    end

    def test_hash_conversions_preserve_key_identity
      MAPS.reject { it < Abstract::TreeMap }.each do |type|
        first = String.new("key").freeze
        second = String.new("key").freeze
        source = new_map(type, nil, compare_keys_by_identity: true)
        source[first] = :first
        source[second] = :second

        [source.to_h, source.to_hash, source.deconstruct_keys([first]),
         source.to_h { |key, value| [key, value] }].each do |hash|
          assert_predicate hash, :compare_by_identity?, type.name
          assert_equal 2, hash.size
          assert_equal :first, hash[first]
          assert_equal :second, hash[second]
          hash.clear

          assert_equal 2, source.size
        end
      end
    end

    def test_hash_pattern_matching
      MAPS.each do |type|
        source = new_map(type, { a: 1, b: nil, c: false })

        assert((source in { a: 1, b: nil, c: false }))
        refute((source in { missing: nil }))
        refute((source in { a: 1, **nil }))
        source => { a: 1, **rest }

        assert_equal({ b: nil, c: false }, rest)
        assert_equal({ a: 1, b: nil, c: false }, source.deconstruct_keys(nil))
        assert_equal source.to_h, source.deconstruct_keys([:a])
        source.deconstruct_keys(nil).clear

        assert_equal 3, source.size
        assert((new_map(type, {}) in {}))
        refute((source in {}))
      end
    end

    def test_deconstruction_uses_canonical_keys_without_normalizing_again
      MAPS.each do |type|
        source = new_map(type, { 1 => :value }, normalize_keys: :succ)

        assert_equal({ 2 => :value }, source.deconstruct_keys([2]))
        assert_equal source.to_h, source.deconstruct_keys(nil)
      end
    end

    def test_identity_hash_conversion_validates_block_results
      source = Unshared::Map.new({ a: 1 }, compare_keys_by_identity: true)
      pair = Object.new
      def pair.to_ary = [:b, 2]

      assert_equal 2, source.to_h { pair }[:b]
      assert_raises(TypeError) { source.to_h { :invalid } }
      assert_raises(ArgumentError) { source.to_h { [] } }
      assert_raises(ArgumentError) { source.to_h { [1, 2, 3] } }
    end

    def test_map_constructor_inputs_are_not_coerced_to_hashes
      source = Unshared::Map.new({ 1 => :value })
      def source.to_hash = raise("map inputs should be iterated directly")

      MAPS.each do |type|
        assert_equal({ 1 => :value }, new_map(type, source).to_h, type.name)
      end

      mapping = Object.new
      def mapping.to_hash = { 1 => :coerced }

      assert_equal({ 1 => :coerced }, Unshared::Map.new(mapping).to_h)
    end

    def test_lease_map_conversions_keep_handle_semantics
      [LeaseMap, Unshared::LeaseMap, Local::LeaseMap].each do |type|
        source = type.new { { a: [] } }
        lease = source.lease_for(:a)

        assert_equal({ "a" => lease }, source.to_h { |key, handle| [key.to_s, handle] })
        assert_equal({ a: lease }, source.to_hash)
        assert_equal({ a: lease }, {}.merge(source))
        assert_same lease, source.deconstruct_keys([:a])[:a]
        source => { a: handle }

        assert_same lease, handle
        assert_equal source.inspect, source.to_s
        %i[slice except transform_keys transform_values invert to_proc merge flatten].each do |name|
          refute_respond_to source, name
        end

        assert_equal Enumerable, source.method(:compact).owner
        assert source.available?(:a)
      end
    end

    private

    def new_map(type, entries, **options)
      options[:max_size] = 5 if type < Abstract::BoundedMap
      type.new(entries, **options)
    end
  end
end
