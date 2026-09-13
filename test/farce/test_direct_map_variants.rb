# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestDirectMapVariants < Test
    DIRECT_VARIANTS = [
      Strict::Map,
      Strict::WeakKeyMap,
      Strict::WeakValueMap,
      Strict::WeakMap,
      Unshared::Map,
      Unshared::WeakKeyMap,
      Unshared::WeakValueMap,
      Unshared::WeakMap
    ].freeze

    STRICT_VARIANTS   = DIRECT_VARIANTS.first(4).freeze
    UNSHARED_VARIANTS = DIRECT_VARIANTS.last(4).freeze

    def test_public_hierarchy_describes_retention
      assert_equal Abstract::ConcurrentMap, Strict::Map.superclass
      assert_equal Abstract::WeakKeyMap, Strict::WeakKeyMap.superclass
      assert_equal Abstract::WeakValueMap, Strict::WeakValueMap.superclass
      assert_equal Abstract::WeakMap, Strict::WeakMap.superclass
      assert_equal Abstract::ConcurrentMap, Unshared::Map.superclass
      assert_equal Abstract::WeakKeyMap, Unshared::WeakKeyMap.superclass
      assert_equal Abstract::WeakValueMap, Unshared::WeakValueMap.superclass
      assert_equal Abstract::WeakMap, Unshared::WeakMap.superclass

      DIRECT_VARIANTS.each { assert_operator it, :<, Abstract::ConcurrentMap }
    end

    def test_weakness_flags
      expectations = {
        Strict::Map            => [false, false],
        Strict::WeakKeyMap     => [true, false],
        Strict::WeakValueMap   => [false, true],
        Strict::WeakMap        => [true, true],
        Unshared::Map          => [false, false],
        Unshared::WeakKeyMap   => [true, false],
        Unshared::WeakValueMap => [false, true],
        Unshared::WeakMap      => [true, true],
      }

      expectations.each do |klass, flags|
        map = klass.new

        assert_equal flags, [map.weak_keys?, map.weak_values?]
      end
    end

    def test_direct_interface_and_iteration_return_the_public_map
      DIRECT_VARIANTS.each do |klass|
        map = klass.new({ one: 1, nil_value: nil })

        assert_equal 1, map[:one]
        assert map.key?(:nil_value)
        assert_equal 2, map.store(:one, 2, timeout: 0)
        assert_equal 2, map.swap(:one, 3, timeout: 0)
        assert map.compare_and_set(:one, 3, 4, timeout: 0)
        assert_equal 5, map.update(:one, timeout: 0) { |value| value + 1 }
        assert_equal 6, map.upsert(:one, 0, timeout: 0) { |value| value + 1 }
        assert_equal 7, map.store_if_absent(:missing, timeout: 0) { 7 }
        assert_equal 6, map.wait_until_non_nil(:one, timeout: 0)
        assert_equal 6, map.wait_until_changed(:one, 0, timeout: 0)
        assert_equal({ one: 6, nil_value: nil, missing: 7 }, map.each.to_h)
        assert_equal [6, nil, 7].tally, map.values.tally
        pairs = []
        keys = []
        values = []

        assert_same(map, map.each { |pair| pairs << pair })
        assert_same(map, map.each_key { |key| keys << key })
        assert_same(map, map.each_value { |value| values << value })
        assert_equal 3, pairs.size
        assert_equal 3, keys.size
        assert_equal 3, values.size
        assert_same map, map.clear
        assert_empty map
      end
    end

    def test_fetch_reports_the_public_receiver_and_preserves_block_errors
      DIRECT_VARIANTS.each do |klass|
        map = klass.new
        error = assert_raises(KeyError) { map.fetch(:missing) }

        assert_same map, error.receiver
        assert_equal :missing, error.key

        block_error = KeyError.new("from block")
        raised = assert_raises(KeyError) { map.fetch(:missing) { raise block_error } }

        assert_same block_error, raised
      end
    end

    def test_constructor_and_comparison_options
      DIRECT_VARIANTS.each do |klass|
        key = String.new("key").freeze
        equal_key = "key".dup.freeze
        value = String.new("value").freeze
        equal_value = "value".dup.freeze
        map = klass.new({ key => value }, compare_by_identity: true)

        assert_same value, map[key]
        assert_nil map[equal_key]
        refute map.compare_and_set(key, equal_value, :replacement)
        assert_predicate map, :compare_keys_by_identity?
        assert_predicate map, :compare_values_by_identity?
        assert_raises(TypeError) { klass.new([]) }
        assert_raises(ArgumentError) { klass.new(compare_by_identity: nil) }
      end
    end

    def test_direct_variants_reject_transfer_modes
      DIRECT_VARIANTS.each do |klass|
        assert_raises(ArgumentError) { klass.new(mode: :copy) }

        map = klass.new

        assert_raises(ArgumentError) { map.store(:key, :value, mode: :copy) }
        assert_raises(ArgumentError) { map.update(:key, mode: :copy) { :value } }
      end
    end

    def test_strict_variants_are_shareable_and_reject_unshareable_inputs
      rejected = Unshared::Queue.new

      STRICT_VARIANTS.each do |klass|
        map = klass.new

        assert_predicate map, :ractor_shareable?
        assert_predicate map, :frozen?
        assert Ractor.shareable?(map)
        assert_predicate map, :shareable_keys?
        assert_predicate map, :shareable_values?
        assert_raises(Ractor::IsolationError) { klass.new({ rejected => 1 }) }
        assert_raises(Ractor::IsolationError) { klass.new({ key: rejected }) }
        assert_raises(Ractor::IsolationError) { map[rejected] }
        assert_raises(Ractor::IsolationError) { map[:key] = rejected }
        assert_raises(Ractor::IsolationError) { map.store_if_absent(:key) { rejected } }
        assert_raises(Ractor::IsolationError) { map.update(:key) { rejected } }
        assert_raises(Ractor::IsolationError) { map.upsert(:key, rejected) { :value } }
        assert_raises(Ractor::IsolationError) { map.compare_and_set(:key, rejected, :value) }
        assert_raises(Ractor::IsolationError) { map.wait_until_changed(:key, rejected, timeout: 0) }
        assert_empty map
      end
    end

    def test_unshared_variants_accept_mutable_objects
      UNSHARED_VARIANTS.each do |klass|
        key = Object.new
        value = []
        map = klass.new({ key => value })

        assert_same value, map[key]
        refute_predicate map, :ractor_shareable?
        refute Ractor.shareable?(map)
        assert_raises(NoMethodError) { map.freeze }
      end
    end

    def test_weak_keys_are_collected
      classes = [Strict::WeakKeyMap, Strict::WeakMap, Unshared::WeakKeyMap, Unshared::WeakMap]

      classes.each do |klass|
        map, retained_value = build_weak_entry(klass, retain: :value)

        assert_collects_entry(map)
        assert retained_value
      end
    end

    def test_weak_values_are_collected
      classes = [Strict::WeakValueMap, Strict::WeakMap, Unshared::WeakValueMap, Unshared::WeakMap]

      classes.each do |klass|
        map, retained_key = build_weak_entry(klass, retain: :key)

        assert_collects_entry(map)
        assert retained_key
      end
    end

    private

    def build_weak_entry(klass, retain:)
      Thread.new do
        key = Object.new
        value = Object.new
        if klass.name.start_with?("Farce::Strict::")
          key.freeze
          value.freeze
        end
        map = klass.new({ key => value })
        [map, retain == :key ? key : value]
      end.value
    end

    def assert_collects_entry(map)
      20.times do
        2_000.times { Object.new }
        RUBY_ENGINE == "jruby" ? java.lang.System.gc : GC.start
        return assert_empty(map) if map.empty?
        sleep 0.01
      end

      flunk "weak map entry remained reachable after repeated full collections"
    end
  end
end
