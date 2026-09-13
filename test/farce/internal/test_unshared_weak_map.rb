# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../../setup"
require "weakref"

module Farce
  module Internal
    class TestUnsharedWeakMap < Test
      include Helpers::InternalTestHelpers
      include Helpers::WeakMapContract

      MAP_NAMES = %i[UnsharedWeakKeyMap UnsharedWeakValueMap UnsharedWeakMap].freeze

      class YieldingWeakEqualityKey
        attr_reader :rank

        def initialize(rank, yield_fiber: false, yield_thread: false)
          @rank = rank
          @yield_fiber = yield_fiber
          @yield_thread = yield_thread
          freeze
        end

        def hash = 0

        def eql?(other)
          Fiber.scheduler&.kernel_sleep(0.01) if @yield_fiber
          Thread.pass if @yield_thread
          other.is_a?(YieldingWeakEqualityKey) && rank == other.rank
        end
      end

      def map_classes = MAP_NAMES.map { |name| Internal.const_get(name, false) }

      def teardown
        Fiber.set_scheduler(nil) if Fiber.respond_to?(:scheduler) && Fiber.scheduler
      end

      def test_key_equality_does_not_hold_native_mutex_across_fiber_yield
        skip "Fiber scheduler is unavailable" unless Fiber.respond_to?(:set_scheduler)

        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        map = UnsharedWeakValueMap.new
        map[YieldingWeakEqualityKey.new(1, yield_fiber: true)] = :one
        events = []

        Fiber.schedule do
          events << :lookup
          events << map[YieldingWeakEqualityKey.new(2, yield_fiber: true)]
        end
        Fiber.schedule do
          events << :size
          events << map.size
        end
        Fiber.set_scheduler(nil)

        assert_equal %i[lookup size], events.first(2)
        assert_includes [[nil, 1], [1, nil]], events.drop(2)
        assert_operator scheduler.io_wait_calls + scheduler.block_calls, :>=, 1
        assert_equal :one, map[YieldingWeakEqualityKey.new(1)]
      end

      def test_key_equality_thread_pass_contention_stress
        map = UnsharedWeakValueMap.new
        map[YieldingWeakEqualityKey.new(-1, yield_thread: true)] = -1
        threads = 4.times.map do |worker|
          Thread.new do
            30.times do |index|
              rank = (worker * 100) + index
              map[YieldingWeakEqualityKey.new(rank, yield_thread: true)] = rank
            end
          end
        end

        threads.each do |thread|
          assert thread.join(10), "weak-map comparator worker deadlocked"
          thread.value
        end

        assert_equal 121, map.size
      ensure
        threads&.each { |thread| thread.kill if thread.alive? }
      end

      def test_simple_store_contention_does_not_block_a_fiber_scheduler
        skip "Fiber scheduler is unavailable" unless Fiber.respond_to?(:set_scheduler)

        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        map = UnsharedWeakValueMap.new({ key: 1 })
        events = []

        Fiber.schedule do
          events << :updating
          map.update(:key) do |old|
            Fiber.scheduler.kernel_sleep(0.01)
            events << :update_finished
            old + 1
          end
        end
        Fiber.schedule do
          events << :store_waiting
          map[:key] = 3
          events << :stored
        end
        Fiber.set_scheduler(nil)

        assert_equal %i[updating store_waiting update_finished stored], events
        assert_equal 3, map[:key]
        assert_operator scheduler.io_wait_calls + scheduler.block_calls, :>=, 1
      end

      def test_flags_and_engine_aliases
        map_classes.zip([[true, false], [false, true], [true, true]]).each do |klass, flags|
          map = klass.new

          assert_equal flags, [map.weak_keys?, map.weak_values?]
          refute Ractor.shareable?(map) if RUBY_ENGINE == "ruby"
          next if RUBY_ENGINE == "ruby"

          name = klass.name.split("::").last.delete_prefix("Unshared")

          assert_same klass, Internal.const_get(name, false)
        end
      end

      def test_mutable_inputs_and_update_results
        map_classes.each do |klass|
          key = Object.new
          value = []
          map = klass.new
          map[key] = value

          assert_same value, map[key]
          assert_same key, map.getkey(key)
          assert_same value, map.update(key) { |old| old << :changed }
          refute_predicate key, :frozen?
          refute_predicate value, :frozen?
          assert_equal [:changed], value
        end
      end

      def test_immediate_keys_and_values
        map_classes.each do |klass|
          [false, true].each do |identity|
            map = klass.new(compare_keys_by_identity: identity)
            [nil, false, true, :symbol, 42, 1.5].each { |key| map[key] = key }
            collect_garbage

            assert_equal 6, map.size
            [nil, false, true, :symbol, 42, 1.5].each do |key|
              assert map.key?(key)
              key.nil? ? assert_nil(map.fetch(key)) : assert_same(key, map.fetch(key))
            end
          end
        end
      end

      def test_key_equality_modes_preserve_original_keys
        map_classes.each do |klass|
          [false, true].each do |identity|
            first = +"equal"
            second = +"equal"
            map = klass.new(compare_keys_by_identity: identity)
            map[first] = 1
            map[second] = 2

            assert_equal identity ? 2 : 1, map.size
            assert_equal identity ? 1 : 2, map[first]
            assert_same first, map.getkey(first)
            assert_same identity ? second : first, map.getkey(second)
          end
        end
      end

      def test_different_keys_can_update_while_one_key_is_reserved
        map_classes.each do |klass|
          map = klass.new({ first: 1, second: 2 })
          entered = Thread::Queue.new
          release = Thread::Queue.new
          worker = Thread.new do
            map.update(:first) do |old|
              entered << true
              release.pop
              old + 1
            end
          end
          Timeout.timeout(5) { entered.pop }

          assert_equal 3, map.update(:second, timeout: 0) { |old| old + 1 }
          assert_equal 4, map.store(:third, 4, timeout: 0)
          assert_nil map.get(:missing, timeout: 0) { flunk "unrelated key blocked" }
        ensure
          release << true if release
          worker&.join(5) || worker&.kill
        end
      end

      def test_nested_updates_only_reject_the_same_key
        map_classes.each do |klass|
          map = klass.new({ first: 1, second: 2 })

          assert_equal 4, map.update(:first) { |old| old + map.update(:second) { |other| other + 1 } }
          assert_raises(ThreadError) { map.update(:first) { map[:first] = 9 } }
          assert_equal 4, map[:first]
          assert_equal 5, map.update(:first) { |old| old + 1 }
        end
      end

      def test_update_exception_preserves_presence_and_releases_reservation
        map_classes.each do |klass|
          map = klass.new({ present: nil, counter: 1 })

          %i[present counter missing].each do |key|
            assert_raises(RuntimeError) { map.update(key) { raise "abort" } }
          end

          assert map.key?(:present)
          assert_nil map[:present]
          assert_equal 1, map[:counter]
          refute map.key?(:missing)
          assert_equal 2, map.update(:counter) { |old| old + 1 }
          assert_equal 3, map.store_if_absent(:missing) { 3 }
        end
      end

      def test_clear_wakes_waiters_and_allows_reinsertion
        map_classes.each do |klass|
          map = klass.new({ key: 1 })
          skip "Fiber scheduler is unavailable" unless Fiber.respond_to?(:set_scheduler)

          scheduler = Helpers::QueueTestScheduler.new
          Fiber.set_scheduler(scheduler)
          events = []
          Fiber.schedule do
            events << :waiting
            events << map.wait_until_changed(:key, 1, timeout: 1) { :timeout }
          end
          Fiber.schedule { map.clear }
          Fiber.set_scheduler(nil)

          assert_equal [:waiting, nil], events
          map[:key] = 2

          assert_equal 2, map[:key]
          assert_equal 1, map.size
        end
      end

      class ObservedWaitValue
        def initialize(entered) = @entered = entered

        def ==(other)
          @entered << true
          other == :expected
        end
      end

      def test_waiter_retains_the_stored_key_until_a_change
        [UnsharedWeakKeyMap, UnsharedWeakMap].each do |klass|
          entered = Thread::Queue.new
          map = Thread.new do
            key = shared_string("key")
            klass.new({ key => ObservedWaitValue.new(entered) })
          end.value
          key = shared_string("key")
          waiter = Thread.new { map.wait_until_changed(key, :expected) }
          begin
            assert entered.pop(timeout: 2)
            10.times { collect_garbage }
            map[key] = :changed

            assert waiter.join(2), "waiter remained on a collected entry"
            assert_includes [nil, :changed], waiter.value
          ensure
            waiter.kill if waiter.alive?
            waiter.join
          end
        end
      end

      def test_waiter_follows_reinserted_entry
        map_classes.each do |klass|
          map = klass.new({ key: nil })
          skip "Fiber scheduler is unavailable" unless Fiber.respond_to?(:set_scheduler)

          scheduler = Helpers::QueueTestScheduler.new
          Fiber.set_scheduler(scheduler)
          events = []
          Fiber.schedule do
            events << :waiting
            events << map.wait_until_non_nil(:key, timeout: 1) { :timeout }
          end
          Fiber.schedule do
            map.delete(:key)
            map[:key] = 7
          end
          Fiber.set_scheduler(nil)

          assert_equal [:waiting, 7], events
          assert_equal 7, map[:key]
          assert_equal 1, map.size
        end
      end

      {
        UnsharedWeakKeyMap:   [:key],
        UnsharedWeakValueMap: [:value],
        UnsharedWeakMap:      %i[key value],
      }.each do |name, sides|
        sides.each do |side|
          [false, true].each do |identity|
            mode = identity ? :identity : :equality
            define_method("test_#{name}_collects_#{side}_with_#{mode}") do
              if side == :key && identity && %w[jruby truffleruby].include?(RUBY_ENGINE)
                # ObjectSpace::WeakMap retains keys on these engines.
                # https://github.com/jruby/jruby/issues/8456
                # https://github.com/truffleruby/truffleruby/issues/2547
                skip "upstream ObjectSpace::WeakMap does not collect keys"
              end
              klass = Internal.const_get(name, false)
              map, retained = build_entry(klass, identity:, retain: side == :key ? :value : :key)

              assert_eventually_empty(map)
              refute_nil retained
              assert_empty map.keys
              assert_empty map.each.to_a
            end
          end
        end
      end

      def test_strong_sides_survive_without_external_references
        [false, true].each do |identity|
          map, key = build_entry(UnsharedWeakKeyMap, identity:, retain: :key)
          3.times { collect_garbage }

          refute_nil map[key]
          assert_equal 1, map.size
          map, value = build_entry(UnsharedWeakValueMap, identity:, retain: :value)
          3.times { collect_garbage }

          assert_equal 1, map.size
          assert_same value, map.fetch(map.keys.first)
        end
      end

      def test_live_weak_values_do_not_lose_their_wrapper
        map_classes.each do |klass|
          key = Object.new
          value = Object.new
          map = klass.new
          map[key] = value
          3.times { collect_garbage }

          assert_same value, map[key]
          assert_same key, map.getkey(key)
        end
      end

      def test_equal_keys_share_a_reservation
        map_classes.each do |klass|
          first = +"key"
          equal = +"key"
          map = klass.new
          map[first] = 1
          entered = Thread::Queue.new
          release = Thread::Queue.new
          worker = Thread.new do
            map.update(first) do |old|
              entered << true
              release.pop
              old + 1
            end
          end
          Timeout.timeout(5) { entered.pop }

          assert_equal :timeout, map.store(equal, 9, timeout: 0) { :timeout }
          release << true

          assert worker.join(5), "update did not finish"
          assert_equal 2, worker.value
          assert_equal 2, map[equal]
          assert_equal 1, map.size
        ensure
          release << true if release
          worker&.kill if worker&.alive?
        end
      end

      def test_identity_distinct_equal_keys_have_independent_reservations
        map_classes.each do |klass|
          first = +"key"
          equal = +"key"
          map = klass.new(compare_keys_by_identity: true)
          map[first] = 1

          assert_equal(2, map.update(first) do |old|
            map.store(equal, 9, timeout: 0)
            old + 1
          end)
          assert_equal 9, map[equal]
          assert_equal 2, map.size
        end
      end

      def test_comparison_option_defaults_and_overrides
        map_classes.each do |klass|
          map = klass.new(compare_by_identity: true)

          assert_predicate map, :compare_keys_by_identity?
          assert_predicate map, :compare_values_by_identity?
          map = klass.new(compare_by_identity: true, compare_keys_by_identity: false)

          refute_predicate map, :compare_keys_by_identity?
          assert_predicate map, :compare_values_by_identity?
          map = klass.new(compare_by_identity: true, compare_values_by_identity: false)

          assert_predicate map, :compare_keys_by_identity?
          refute_predicate map, :compare_values_by_identity?
        end
      end

      def test_absent_reads_and_timeouts_do_not_create_entries
        map_classes.each do |klass|
          map = klass.new
          key = Object.new

          assert_nil map[key]
          refute map.key?(key)
          assert_equal :timeout, map.wait_until_non_nil(key, timeout: 0) { :timeout }
          refute map.compare_and_set(key, nil, 1)
          assert_equal 0, map.size
          assert_empty map.each.to_a
          assert_nil map.store_if_absent(key) { nil }
          assert map.key?(key)
          assert map.compare_and_set(key, nil, 1)
          assert_equal 1, map[key]
        end
      end

      def test_update_runs_in_the_calling_fiber
        map_classes.each do |klass|
          map = klass.new({ key: 1 })
          caller_fiber = Fiber.current
          caller_thread = Thread.current
          calls = 0
          result = map.update(:key) do |old|
            assert_same caller_fiber, Fiber.current
            assert_same caller_thread, Thread.current
            calls += 1
            old + 1
          end

          assert_equal 2, result
          assert_equal 1, calls
        end
      end

      def test_collecting_a_weak_value_releases_its_strong_key
        [false, true].each do |identity|
          map, weak_key = Thread.new do
            key = Object.new
            map = UnsharedWeakValueMap.new(compare_keys_by_identity: identity)
            map[key] = Object.new
            [map, WeakRef.new(key)]
          end.value

          assert_eventually_empty(map)
          assert_reference_collected(weak_key)
        end
      end

      def test_collecting_a_weak_key_releases_its_strong_value
        map, weak_value = Thread.new do
          value = Object.new
          map = UnsharedWeakKeyMap.new
          map[Object.new] = value
          [map, WeakRef.new(value)]
        end.value

        assert_eventually_empty(map)
        assert_reference_collected(weak_value)
      end

      def test_can_be_created_locally_inside_a_ractor
        skip "native ractors are unavailable" unless RUBY_ENGINE == "ruby"

        map_classes.each do |klass|
          worker = Ractor.new(klass) do |map_class|
            map = map_class.new(compare_by_identity: true)
            key = Object.new
            value = []
            map[key] = value
            [map[key].equal?(value), map.getkey(key).equal?(key), map.size]
          end

          assert_equal [true, true, 1], ractor_value(worker)
        end
      end

      def test_clear_invalidates_an_inflight_update
        map_classes.each do |klass|
          map = klass.new({ key: 1 })
          entered = Thread::Queue.new
          release = Thread::Queue.new
          calls = 0
          worker = Thread.new do
            map.update(:key) do |old|
              calls += 1
              entered << true
              release.pop
              old + 1
            end
          end
          Timeout.timeout(5) { entered.pop }
          map.clear
          map[:key] = 9
          release << true

          assert worker.join(5), "retired update did not finish"
          assert_nil worker.value
          assert_equal 1, calls
          assert_equal 9, map[:key]
          assert_equal 1, map.size
        ensure
          release << true if release
          worker&.kill if worker&.alive?
        end
      end

      def test_ordinary_reads_reclaim_dead_entries
        map, references = Thread.new do
          map = UnsharedWeakValueMap.new
          references = 10.times.map do
            key = Object.new
            map[key] = Object.new
            WeakRef.new(key)
          end
          [map, references]
        end.value

        50.times do
          collect_garbage
          30.times { map[:missing] }
          collected = references.none?(&:weakref_alive?)
          return assert(collected) if collected
          sleep 0.01
        end

        flunk "ordinary reads did not release dead entries' strong keys"
      end

      def test_idle_equality_weak_key_map_releases_its_value
        # Direct ObjectSpace::WeakKeyMap controls show that these runtimes
        # release stale values on access. Preserve the primitive's behavior.
        skip "ObjectSpace::WeakKeyMap defers value cleanup until access" if %w[jruby truffleruby].include?(RUBY_ENGINE)

        map, weak_value = Thread.new do
          value = Object.new
          map = UnsharedWeakKeyMap.new
          map[Object.new] = value
          [map, WeakRef.new(value)]
        end.value

        # Do not access the map until collection is proved. Housekeeping must
        # not be required to release a strong value whose weak key disappeared.
        assert_reference_collected(weak_value)
        assert_equal 0, map.size
      end

      MAP_NAMES.each do |map_name|
        define_method("test_#{map_name}_compares_keys_with_eql") do
          if RUBY_ENGINE == "jruby" && map_name != :UnsharedWeakValueMap
            skip "upstream ObjectSpace::WeakKeyMap uses == instead of eql?"
          end

          key_class = Class.new do
            attr_reader :rank

            def initialize(rank) = @rank = rank
            def hash = 0
            def eql?(other) = rank == other.rank
            def ==(_other) = false
          end
          key = key_class.new(1)
          equivalent = key_class.new(1)
          distinct = key_class.new(2)
          map = Internal.const_get(map_name, false).new
          map[key] = :value

          assert_equal :value, map[equivalent]
          assert_nil map[distinct]
          assert_same key, map.getkey(equivalent)
        end
      end

      def test_key_hash_exception_releases_index_access
        key_class = Class.new do
          attr_accessor :raise_on_hash
          attr_reader :rank

          def initialize(rank) = @rank = rank

          def hash
            raise "hash failed" if raise_on_hash
            0
          end

          def eql?(other) = rank == other.rank
        end
        map_classes.each do |klass|
          first = key_class.new(1)
          second = key_class.new(2)
          map = klass.new
          map[first] = 1
          second.raise_on_hash = true
          called = false

          assert_raises(RuntimeError) { map.update(second) { called = true } }
          refute called
          second.raise_on_hash = false

          assert_equal 1, map[first]
          assert_equal 2, map.store(second, 2, timeout: 0)
          assert_equal 2, map.size
        end
      end

      private

      def build_entry(klass, identity:, retain:)
        Thread.new do
          key = Object.new
          value = Object.new
          map = klass.new(compare_keys_by_identity: identity)
          map[key] = value
          [map, retain == :key ? key : value]
        end.value
      end

      def collect_garbage
        # JRuby GC.start is a no-op. Ask its VM directly for a collection.
        RUBY_ENGINE == "jruby" ? java.lang.System.gc : GC.start
      end

      def assert_reference_collected(reference)
        50.times do
          collect_garbage
          return refute_predicate(reference, :weakref_alive?) unless reference.weakref_alive?
          sleep 0.01
        end

        flunk "removed entry retained its strong side"
      end

      def assert_eventually_empty(map)
        50.times do
          2_000.times { Object.new }
          collect_garbage
          return assert_equal(0, map.size) if map.size.zero? # rubocop:disable Style/ZeroLengthPredicate
          sleep 0.01
        end

        flunk "weak entry remained reachable after repeated collections"
      end
    end
  end
end
