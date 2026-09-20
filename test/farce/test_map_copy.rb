# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestMapCopy < Test
    include Helpers::InternalTestHelpers

    TREE_TYPES = [TreeMap, Strict::TreeMap, Unshared::TreeMap, Unsafe::TreeMap, Local::TreeMap].freeze
    BOUNDED_TYPES = [LRUMap, LFUMap, Strict::LRUMap, Strict::LFUMap, Unshared::LRUMap,
                     Unshared::LFUMap, Unsafe::LRUMap, Unsafe::LFUMap, Local::LRUMap, Local::LFUMap].freeze
    WEAK_TYPES = [WeakKeyMap, Strict::WeakKeyMap, Strict::WeakValueMap, Strict::WeakMap,
                  Unshared::WeakKeyMap, Unshared::WeakValueMap, Unshared::WeakMap,
                  Local::WeakKeyMap, Local::WeakValueMap, Local::WeakMap].freeze

    def test_duplicable_matches_copy_support
      (TREE_TYPES + BOUNDED_TYPES + WEAK_TYPES + [Map, Strict::Map, Unshared::Map, Local::Map]).each do |type|
        options = type < Abstract::BoundedMap ? { max_size: 4 } : {}
        source = type.new({ 1 => :value }, **options)

        assert_predicate source, :duplicable?, type.name
        assert_instance_of type, source.dup
        assert_predicate source.dup, :duplicable?, type.name
      end
    end

    def test_backing_storage_is_a_protected_duplicable_map_hook
      (TREE_TYPES + BOUNDED_TYPES + WEAK_TYPES + [Map, Strict::Map, Unshared::Map, Local::Map]).each do |type|
        assert type.protected_method_defined?(:internal_map)
        refute type.public_method_defined?(:internal_map)
        assert_equal Abstract::DuplicableMap, type.instance_method(:initialize_copy).owner
        assert_equal Abstract::DuplicableMap, type.instance_method(:initialize_dup).owner
        assert_equal Abstract::DuplicableMap, type.instance_method(:initialize_clone).owner
      end
      %i[initialize_copy initialize_dup initialize_clone].each do |method|
        refute_equal Abstract::Map, Abstract::Map.instance_method(method).owner
      end
      refute Abstract::Map.method_defined?(:internal_map)
      refute Abstract::Map.private_method_defined?(:internal_map)
      [LeaseMap, Unshared::LeaseMap, Local::LeaseMap].each do |type|
        refute type.method_defined?(:internal_map)
        refute type.private_method_defined?(:internal_map)
      end
    end

    def test_tree_copies_have_independent_storage
      TREE_TYPES.each { assert_independent_copy(it) }
    end

    def test_bounded_copies_have_independent_storage
      BOUNDED_TYPES.each { assert_independent_copy(it, max_size: 4) }
    end

    def test_weak_copies_have_independent_storage
      WEAK_TYPES.each { assert_independent_copy(it) }
    end

    def test_local_map_copies_current_scope
      assert_independent_copy(Local::Map)
    end

    def test_normalized_copies_do_not_normalize_stored_keys_again
      (TREE_TYPES + BOUNDED_TYPES + WEAK_TYPES + [Map, Strict::Map, Unshared::Map, Local::Map]).each do |type|
        options = type < Abstract::BoundedMap ? { max_size: 4 } : {}
        source = type.new({ 1 => :value }, normalize_keys: Ractor.shareable_proc { |key| key + 1 }, **options)
        [source.dup, source.clone].each do |copy|
          assert_equal [2], copy.keys, type.name
          assert_equal :value, copy[1], type.name
          copy[1] = :changed

          assert_equal :value, source[1], type.name
        end
      end
    end

    def test_copies_preserve_value_modes_without_claiming_values
      [TreeMap, LRUMap, LFUMap, WeakKeyMap].each do |type|
        options = type < Abstract::BoundedMap ? { max_size: 4 } : {}
        source = type.new(nil, mode: :move, **options)
        source[1] = []
        envelope = source.instance_variable_get(:@map).each.to_a.first.last
        copy = source.dup

        assert_equal :move, copy.mode
        refute_predicate envelope, :claimed? if Envelope === envelope

        assert_same source[1], copy[1]
        copy.delete(1)

        assert source.key?(1)
      end
    end

    def test_unshared_copies_are_shallow
      [Unshared::TreeMap, Unshared::LRUMap, Unshared::LFUMap,
       Unshared::WeakMap, Unshared::WeakKeyMap, Unshared::WeakValueMap].each do |type|
        options = type < Abstract::BoundedMap ? { max_size: 4 } : {}
        value = []
        source = type.new({ 1 => value }, **options)
        copy = source.dup

        assert_same value, copy[1]
        copy[1] << :changed

        assert_equal [:changed], source[1]
      end
    end

    def test_bounded_copies_preserve_capacity_and_eviction_history
      BOUNDED_TYPES.each do |type|
        source = type.new({ 1 => :a, 2 => :b }, max_size: 3)
        source.max_size = 2
        3.times { source[1] }
        2.times { source[2] }
        copy = source.dup

        assert_equal 2, copy.max_size
        source[3] = :c
        copy[3] = :c

        assert_equal source.keys.sort, copy.keys.sort, type.name
        copy.max_size = 0

        assert_equal 2, source.max_size
        assert_equal 2, source.size
        assert_empty copy
      end
    end

    def test_local_copy_does_not_reuse_other_scopes_storage
      [Local::Map, Local::TreeMap, Local::LRUMap, Local::LFUMap, Local::WeakKeyMap].each do |type|
        options = type < Abstract::BoundedMap ? { max_size: 4 } : {}
        source = type.new({ 1 => :initial }, scope: :fiber, **options)
        source[1] = :current
        copy = source.dup

        assert_equal :fiber, copy.scope
        assert_equal :current, copy[1]
        assert_equal %i[initial initial], Fiber.new { [source[1], copy[1]] }.resume
        Fiber.new { copy[1] = :other_scope }.resume

        assert_equal :current, copy[1]
        assert_equal :current, source[1]
      end
    end

    def test_copies_preserve_identity_comparison_and_distinct_equal_keys
      (WEAK_TYPES + BOUNDED_TYPES + [Local::Map]).each do |type|
        options = type < Abstract::BoundedMap ? { max_size: 4 } : {}
        first = String.new("equal").freeze
        second = String.new("equal").freeze
        source = type.new(compare_keys_by_identity: true, compare_values_by_identity: true, **options)
        source[first] = :first
        source[second] = :second
        copy = source.dup

        assert_predicate copy, :compare_keys_by_identity?
        assert_predicate copy, :compare_values_by_identity?
        assert_equal 2, copy.size, type.name
        assert_equal :first, copy[first], type.name
        assert_equal :second, copy[second], type.name
      end
    end

    def test_tree_and_bounded_copies_do_not_share_loader_locks
      (TREE_TYPES + BOUNDED_TYPES).reject { it.name.include?("::Unsafe::") }.each do |type|
        options = type < Abstract::BoundedMap ? { max_size: 4 } : {}
        source = type.new(**options)
        copy = source.dup
        entered = Queue.new
        release = Queue.new
        worker = Thread.new do
          source.store_if_absent(1) do
            entered << true
            release.pop
            :source
          end
        end

        assert Timeout.timeout(5) { entered.pop }
        assert_equal :copy, Timeout.timeout(5) { copy.store_if_absent(1) { :copy } }, type.name
        release << true

        assert worker.join(5), "loader did not finish"
        assert_equal :source, source[1]
        assert_equal :copy, copy[1]
      ensure
        release << true if release
        worker.kill.join if worker&.alive?
      end
    end

    def test_weak_copies_do_not_share_update_reservations
      WEAK_TYPES.each do |type|
        source = type.new({ 1 => :initial })
        copy = source.dup
        entered = Queue.new
        release = Queue.new
        worker = Thread.new do
          source.update(1) do
            entered << true
            release.pop
            :source
          end
        end

        assert Timeout.timeout(5) { entered.pop }
        assert_equal :copy, copy.update(1, timeout: 0) { :copy }, type.name
        copy.clear
        release << true

        assert worker.join(5), "update did not finish"
        assert_equal :source, source[1]
        assert_empty copy
      ensure
        release << true if release
        worker.kill.join if worker&.alive?
      end
    end

    def test_weak_copies_do_not_keep_weak_entries_alive
      WEAK_TYPES.each do |type|
        source, copy = Thread.new do
          map = type.new
          map[Object.new.freeze] = Object.new.freeze
          [map, map.dup]
        end.value

        20.times do
          2_000.times { Object.new }
          RUBY_ENGINE == "jruby" ? java.lang.System.gc : GC.start
          break if source.empty? && copy.empty?
          sleep 0.01
        end

        assert_empty source, type.name
        assert_empty copy, type.name
      end
    end

    def test_lease_maps_reject_copying_without_changing_ownership
      [LeaseMap, Unshared::LeaseMap, Local::LeaseMap].each do |type|
        source = type.new { { 1 => [] } }

        refute_predicate source, :duplicable?, type.name
        handle = source.lease_for(1)
        source.checkout(1) do |resource|
          assert_raises(TypeError) { source.dup }
          assert_raises(TypeError) { source.clone }
          assert_raises(TypeError) { source.clone(freeze: false) }
          assert_same handle, source.lease_for(1)
          assert source.owned?(1)
          assert_same resource, source[1]
        end
        assert source.available?(1)
      end
    end

    private

    def assert_independent_copy(type, **)
      source = type.new({ 1 => :initial }, **)
      source[1] = :current
      [source.dup, source.clone].each do |copy|
        assert_instance_of type, copy
        assert_equal :current, copy[1], type.name
        if source.is_a?(Shareable)
          assert_predicate copy, :frozen?, type.name
          assert Ractor.shareable?(copy)
          if Internal.native_ractors? && !source.is_a?(Local::Scoped)
            assert_equal :current, ractor_value(Ractor.new(copy) { |map| map[1] })
          end
        end
        copy[1] = :changed
        copy[2] = :added

        assert_equal :current, source[1], type.name
        refute source.key?(2), type.name
        copy.clear

        assert source.key?(1)
      end
    end
  end
end
