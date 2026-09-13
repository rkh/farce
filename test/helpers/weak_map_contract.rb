# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Helpers
  # Shared observable behavior for native, unshared, and future owner-backed maps.
  # Implement map_classes and include InternalTestHelpers in the test class.
  module WeakMapContract
    def test_initial_mapping_and_validation
      map_classes.each do |klass|
        key = shared_string("key")
        value = shared_string("value")
        map = klass.new({ key => value })

        assert_same value, map[key]
        assert_same key, map.getkey(shared_string("key"))
        assert_equal 1, map.size
        assert_raises(TypeError) { klass.new([]) }
        assert_raises(ArgumentError) { klass.new(compare_by_identity: nil) }
        assert_raises(ArgumentError) { klass.new(compare_keys_by_identity: 1) }
        assert_raises(ArgumentError) { klass.new(compare_values_by_identity: :yes) }
      end
    end

    def test_crud_and_stored_nil
      map_classes.each do |klass|
        map = klass.new

        refute map.key?(:key)
        assert_nil map[:key]
        assert_nil(map[:key] = nil)
        assert map.key?(:key)
        assert_equal 1, map.size
        called = false

        assert_nil map.store_if_absent(:key) { called = true }
        refute called
        assert_nil map.delete(:key)
        refute map.key?(:key)
        assert_equal 0, map.size
      end
    end

    def test_clear
      map_classes.each do |klass|
        map = klass.new({ one: 1, two: nil })

        assert_same map, map.clear
        assert_equal 0, map.size
        assert_empty map.keys
        refute map.key?(:one)
        refute map.key?(:two)
        assert_same map, map.clear
        assert_equal 3, map[:three] = 3
        assert_equal({ three: 3 }, map.each.to_h)
      end
    end

    def test_fetch
      map_classes.each do |klass|
        map = klass.new({ present: nil })
        called = false

        assert_nil map.fetch(:present) { called = true }
        refute called
        assert_equal :default, map.fetch(:missing, :default)
        assert_nil map.fetch(:missing, nil)
        assert_equal :block, map.fetch(:missing) { |key| key == :missing ? :block : flunk }

        result = nil
        assert_output(nil, /block supersedes default value argument/) do
          result = map.fetch(:missing, :default) { :block } # rubocop:disable Lint/UselessDefaultValueArgument
        end
        assert_equal :block, result

        error = assert_raises(KeyError) { map.fetch(:missing) }
        assert_equal "key not found: :missing", error.message
        assert_equal :missing, error.key
        assert_same map, error.receiver
        assert_raises(ArgumentError) { map.fetch }
        assert_raises(ArgumentError) { map.fetch(:key, :one, :two) }
      end
    end

    def test_get_store_and_swap
      map_classes.each do |klass|
        map = klass.new({ key: 1 })

        assert_equal 1, map.get(:key, timeout: 0)
        assert_equal 2, map.store(:key, 2, timeout: 0)
        assert_equal 2, map.swap(:key, 3, timeout: 0)
        assert_equal 3, map[:key]
        assert_nil map.swap(:missing, 4)
        assert_equal 4, map[:missing]
      end
    end

    def test_wait_until_changed_and_non_nil
      map_classes.each do |klass|
        map = klass.new({ key: 1 })
        changer = Thread.new do
          sleep 0.01
          map[:key] = 2
        end

        assert_equal 2, map.wait_until_changed(:key, 1, timeout: 1)
        changer.join

        assert_equal 2, map.wait_until_non_nil(:key, timeout: 0)

        missing_changer = Thread.new do
          sleep 0.01
          map[:missing] = 3
        end

        assert_equal 3, map.wait_until_non_nil(:missing, timeout: 1)
        missing_changer.join
      end
    end

    def test_wait_timeout_deletion_and_value_comparison
      map_classes.each do |klass|
        original = shared_string("value")
        equal = shared_string("value")
        map = klass.new({ key: original })

        assert_equal :timeout, map.wait_until_changed(:key, equal, timeout: 0) { :timeout }
        assert_equal :timeout, map.wait_until_non_nil(:missing, timeout: 0) { :timeout }
        deleter = Thread.new do
          sleep 0.01
          map.delete(:key)
        end

        assert_nil map.wait_until_changed(:key, original, timeout: 1) { flunk "did not observe deletion" }
        deleter.join

        identity_map = klass.new({ key: original }, compare_values_by_identity: true)

        assert_same original, identity_map.wait_until_changed(:key, equal, timeout: 0)
      end
    end

    def test_timed_aliases_fall_back_during_an_atomic_update
      map_classes.each do |klass|
        map = klass.new({ key: 1 })
        entered = Thread::Queue.new
        release = Thread::Queue.new
        updater = Thread.new do
          map.upsert(:key, 0) do |old|
            entered << true
            release.pop
            old + 1
          end
        end
        entered.pop

        assert_equal :get_timeout, map.get(:key, timeout: 0) { :get_timeout }
        assert_equal :store_timeout, map.store(:key, 9, timeout: 0) { :store_timeout }
        assert_equal :swap_timeout, map.swap(:key, 9, timeout: 0) { :swap_timeout }
        store_if_absent_called = false
        upsert_called = false

        assert_nil map.store_if_absent(:key, timeout: 0) { store_if_absent_called = true }
        refute map.compare_and_set(:key, 1, 9, timeout: 0)
        update_called = false

        assert_nil map.update(:key, timeout: 0) { update_called = true }
        assert_nil map.upsert(:key, 0, timeout: 0) { upsert_called = true }
        refute store_if_absent_called
        refute update_called
        refute upsert_called
      ensure
        release << true if release
        updater&.join
      end
    end

    def test_wait_and_alias_timeout_validation
      map_classes.each do |klass|
        map = klass.new

        assert_raises(ArgumentError) { map.get(:key, timeout: -1) }
        assert_raises(ArgumentError) { map.store(:key, 1, timeout: Float::INFINITY) }
        assert_raises(ArgumentError) { map.swap(:key, 1, timeout: Float::NAN) }
        assert_raises(ArgumentError) { map.store_if_absent(:key, timeout: -1) { 1 } }
        assert_raises(ArgumentError) { map.compare_and_set(:key, nil, 1, timeout: -1) }
        assert_raises(ArgumentError) { map.update(:key, timeout: -1) { 1 } }
        assert_raises(ArgumentError) { map.upsert(:key, 1, timeout: -1) { 2 } }
        assert_raises(ArgumentError) { map.wait_until_changed(:key, nil, timeout: -1) }
        assert_raises(ArgumentError) { map.wait_until_non_nil(:key, timeout: -1) }
      end
    end

    def test_store_if_absent_executes_once
      map_classes.each do |klass|
        map = klass.new
        calls = 0
        lock = Mutex.new
        threads = 8.times.map do
          Thread.new do
            map.store_if_absent(:key) do
              lock.synchronize { calls += 1 }
              sleep 0.005
              42
            end
          end
        end

        assert_equal [42], threads.map(&:value).uniq
        assert_equal 1, calls
      end
    end

    def test_compare_and_set_and_upsert
      map_classes.each do |klass|
        original = shared_string("value")
        equal = shared_string("value")
        map = klass.new({ key: original })

        assert map.compare_and_set(:key, equal, :replacement, timeout: 0)
        assert_equal :replacement, map[:key]
        refute map.compare_and_set(:missing, nil, :nope)
        assert_equal :replacement2, map.upsert(:key, :initial) { :replacement2 }
        called = false

        assert_equal :initial, map.upsert(:missing, :initial, timeout: 0) { called = true }
        refute called
      end
    end

    def test_concurrent_updates
      map_classes.each do |klass|
        map = klass.new({ counter: 0 })
        threads = 8.times.map do
          Thread.new { 50.times { map.update(:counter) { |old| old + 1 } } }
        end
        threads.each(&:join)

        assert_equal 400, map[:counter]
      end
    end

    def test_identity_comparison
      map_classes.each do |klass|
        stored_key = shared_string("key")
        equal_key = shared_string("key")
        stored_value = shared_string("value")
        equal_value = shared_string("value")
        map = klass.new(compare_keys_by_identity: true, compare_values_by_identity: true)
        map[stored_key] = stored_value

        assert_same stored_value, map[stored_key]
        assert_nil map[equal_key]
        assert_same stored_key, map.getkey(stored_key)
        refute map.compare_and_set(stored_key, equal_value, :nope)
        assert map.compare_and_set(stored_key, stored_value, :replacement)
        assert_predicate map, :compare_keys_by_identity?
        assert_predicate map, :compare_values_by_identity?
      end
    end

    def test_iteration
      map_classes.each do |klass|
        first = shared_string("first")
        second = shared_string("second")
        expected = { first => 1, second => nil }
        map = klass.new(expected)

        assert_equal expected.keys.sort, map.keys.sort
        stored_first = map.keys.find { |key| key == first }

        assert_same first, stored_first

        each = map.each
        each_pair = map.each_pair
        each_key = map.each_key
        each_value = map.each_value

        assert_kind_of Enumerator, each
        assert_kind_of Enumerator, each_pair
        assert_kind_of Enumerator, each_key
        assert_kind_of Enumerator, each_value
        assert_equal 2, each.size
        assert_equal 2, each_pair.size
        assert_equal 2, each_key.size
        assert_equal 2, each_value.size
        assert_equal expected, each.to_h
        assert_equal expected, each_pair.to_h
        assert_equal expected.values.tally, each_value.to_a.tally

        pairs = []
        result = map.each { |pair| pairs << pair }

        assert_same map, result
        assert_equal expected, pairs.to_h

        pairs = []
        result = map.each_pair { |key, value| pairs << [key, value] }

        assert_same map, result
        assert_equal expected, pairs.to_h

        keys = []
        result = map.each_key { |key| keys << key }

        assert_same map, result
        assert_equal expected.keys.sort, keys.sort

        values = []
        result = map.each_value { |value| values << value }

        assert_same map, result
        assert_equal expected.values.tally, values.tally

        map.each { |pair| map.delete(pair.first) }

        assert_equal 0, map.size
      end
    end

    def test_concurrent_upserts
      map_classes.each do |klass|
        map = klass.new({ counter: 0 })
        threads = 8.times.map do
          Thread.new { 100.times { map.upsert(:counter, 0) { |old| old + 1 } } }
        end
        threads.each(&:join)

        assert_equal 800, map[:counter]
      end
    end

    def test_compaction_with_many_live_entries
      map_classes.each do |klass|
        map = klass.new
        keys = 1_000.times.map { |index| shared_string("key-#{index}") }
        values = 1_000.times.map { |index| shared_string("value-#{index}") }
        keys.each_index { |index| map[keys[index]] = values[index] }

        GC.compact if GC.respond_to?(:compact)

        assert_equal 1_000, map.size
        keys.each_index { |index| assert_same values[index], map[keys[index]] }
      end
    end

    def test_nonlocal_block_exit_releases_the_key
      map_classes.each do |klass|
        map = klass.new({ key: 1 })
        result = catch(:abort_update) do
          map.update(:key) { throw :abort_update, :aborted }
        end

        assert_equal :aborted, result
        assert_equal 1, map[:key]
        assert_equal 2, map.update(:key, timeout: 0) { |old| old + 1 }
        assert_equal :aborted, map.store_if_absent(:missing) { break :aborted }
        refute map.key?(:missing)
        assert_equal 3, map.store_if_absent(:missing, timeout: 0) { 3 }
      end
    end
  end
end
