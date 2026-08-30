# frozen_string_literal: true

require_relative "../../setup"

module Farce
  class TestWeakMap < Test
    include Helpers::InternalTestHelpers

    if Internal.const_defined?(:NATIVE_WEAK_MAPS, false)
      WeakKeyMap = Internal::WeakKeyMap
      WeakValueMap = Internal::WeakValueMap
      WeakMap = Internal::WeakMap
      MAP_CLASSES = [WeakKeyMap, WeakValueMap, WeakMap].freeze
    else
      MAP_CLASSES = [].freeze
    end

    def setup
      native = Internal.const_defined?(:NATIVE_WEAK_MAPS, false) && Internal::NATIVE_WEAK_MAPS
      skip "weak-map fallback coverage is intentionally omitted" unless native
    end

    def teardown
      Fiber.set_scheduler(nil) if Fiber.scheduler
    end

    def test_weakness_flags_and_shareability
      expectations = {
        WeakKeyMap   => [true, false],
        WeakValueMap => [false, true],
        WeakMap      => [true, true],
      }

      expectations.each do |klass, flags|
        map = klass.new

        assert_equal flags, [map.weak_keys?, map.weak_values?]
        assert_predicate map, :frozen?
        assert Ractor.shareable?(map)
      end
    end

    def test_initial_mapping_and_validation
      MAP_CLASSES.each do |klass|
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
      MAP_CLASSES.each do |klass|
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

    def test_get_store_and_swap
      MAP_CLASSES.each do |klass|
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
      MAP_CLASSES.each do |klass|
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

    def test_wait_does_not_block_a_fiber_scheduler
      iterations = Internal::NATIVE_WEAK_MAPS ? 1 : 25
      iterations.times do
        MAP_CLASSES.each do |klass|
          scheduler = Helpers::QueueTestScheduler.new
          Fiber.set_scheduler(scheduler)
          map = klass.new
          events = []

          Fiber.schedule do
            events << :waiting
            events << map.wait_until_non_nil(:key)
          end
          Fiber.schedule do
            events << :storing
            map[:key] = :value
          end
          Fiber.set_scheduler(nil)

          assert_equal %i[waiting storing value], events
          assert_operator scheduler.io_wait_calls, :>=, 1
        end
      end
    end

    def test_fallback_fiber_replies_do_not_retain_descriptors
      skip "native weak maps do not use the owner Ractor" if Internal::NATIVE_WEAK_MAPS

      # Warm up the owner request path before taking the baseline. Each
      # Fiber-local reply queue releases its dormant signaling pipe after use.
      WeakMap.new
      before = open_file_descriptor_count
      skip "open descriptor count is not available" unless before

      100.times do
        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        map = WeakMap.new
        Fiber.schedule { map.wait_until_non_nil(:key) }
        Fiber.schedule { map[:key] = :value }
        Fiber.set_scheduler(nil)
      end

      assert_operator open_file_descriptor_count, :<=, before + 2
    end

    def test_wait_timeout_deletion_and_value_comparison
      MAP_CLASSES.each do |klass|
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
      MAP_CLASSES.each do |klass|
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
      MAP_CLASSES.each do |klass|
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
      MAP_CLASSES.each do |klass|
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
      MAP_CLASSES.each do |klass|
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

    def test_update_always_calls_the_block
      MAP_CLASSES.each do |klass|
        map = klass.new({ nil_value: nil, counter: 1 })
        seen = []

        assert_equal 10, map.update(:missing, timeout: 0) { |old|
          seen << old
          10
        }
        assert_equal 11, map.update(:nil_value) { |old|
          seen << old
          11
        }
        assert_equal 2, map.update(:counter) { |old|
          seen << old
          old + 1
        }
        assert_equal [nil, nil, 1], seen
        assert_equal [10, 11, 2], [map[:missing], map[:nil_value], map[:counter]]
        assert_raises(LocalJumpError) { map.update(:key) }
        assert_raises(Ractor::IsolationError) { map.update(:key) { [] } }
        assert_equal 12, map.update(:key) { 12 }
      end
    end

    def test_concurrent_updates
      MAP_CLASSES.each do |klass|
        map = klass.new({ counter: 0 })
        threads = 8.times.map do
          Thread.new { 50.times { map.update(:counter) { |old| old + 1 } } }
        end
        threads.each(&:join)

        assert_equal 400, map[:counter]
      end
    end

    def test_identity_comparison
      MAP_CLASSES.each do |klass|
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

    def test_rejects_unshareable_inputs
      MAP_CLASSES.each do |klass|
        map = klass.new

        assert_raises(Ractor::IsolationError) { map[Object.new] }
        assert_raises(Ractor::IsolationError) { map[Object.new] = 1 }
        assert_raises(Ractor::IsolationError) { map[:key] = Object.new }
        assert_raises(Ractor::IsolationError) { map.store_if_absent(:key) { [] } }
        assert_raises(Ractor::IsolationError) { map.upsert(:key, []) { 1 } }
      end
    end

    def test_concurrent_upserts
      MAP_CLASSES.each do |klass|
        map = klass.new({ counter: 0 })
        threads = 8.times.map do
          Thread.new { 100.times { map.upsert(:counter, 0) { |old| old + 1 } } }
        end
        threads.each(&:join)

        assert_equal 800, map[:counter]
      end
    end

    def test_mutation_from_multiple_ractors
      MAP_CLASSES.each do |klass|
        map = klass.new({ counter: 0 })
        workers = 4.times.map do
          Ractor.new(map) do |shared|
            50.times { shared.upsert(:counter, 0) { |old| old + 1 } }
            :done
          end
        end

        workers.each { |worker| assert_equal :done, ractor_value(worker) }

        assert_equal 200, map[:counter]
      end
    end

    def test_retired_cells_are_not_resurrected
      MAP_CLASSES.each do |klass|
        map = klass.new({ key: 1 })

        assert_equal 1, map[:key]

        worker = Ractor.new(map) { |shared| shared.delete(:key) }

        assert_equal 1, ractor_value(worker)
        map[:key] = 2

        assert_equal 2, map[:key]
        assert_equal 1, map.size
      end
    end

    def test_weak_keys_are_collected
      [WeakKeyMap, WeakMap].each do |klass|
        map, retained_value = build_entry(klass, retain: :value)

        assert_collects(map)
        assert retained_value
      end
    end

    def test_weak_values_are_collected
      [WeakValueMap, WeakMap].each do |klass|
        map, retained_key = build_entry(klass, retain: :key)

        assert_collects(map)
        assert retained_key
      end
    end

    def test_strong_side_remains_reachable
      key = Ractor.make_shareable(Object.new)
      value = Ractor.make_shareable(Object.new)
      weak_key_map = WeakKeyMap.new({ key => value })
      weak_value_map = WeakValueMap.new({ key => value })

      3.times { GC.start }

      assert_same value, weak_key_map[key]
      assert_same value, weak_value_map[key]
    end

    def test_compaction_with_many_live_entries
      MAP_CLASSES.each do |klass|
        map = klass.new
        keys = 1_000.times.map { |index| shared_string("key-#{index}") }
        values = 1_000.times.map { |index| shared_string("value-#{index}") }
        keys.each_index { |index| map[keys[index]] = values[index] }

        GC.compact if GC.respond_to?(:compact)

        assert_equal 1_000, map.size
        keys.each_index { |index| assert_same values[index], map[keys[index]] }
      end
    end

    private

    def build_entry(klass, retain:)
      map = klass.new
      key = Ractor.make_shareable(Object.new)
      value = Ractor.make_shareable(Object.new)
      map[key] = value
      [map, retain == :key ? key : value]
    end

    def assert_collects(map)
      20.times do
        2_000.times { Object.new }
        GC.start
        return assert_equal(0, map.size) if map.size.zero? # rubocop:disable Style/ZeroLengthPredicate
      end

      flunk "weak entry remained reachable after repeated full collections"
    end
  end
end
