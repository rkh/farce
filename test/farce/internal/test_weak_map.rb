# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../../setup"

module Farce
  module Internal
    class TestWeakMap < Test
      include Helpers::InternalTestHelpers
      include Helpers::WeakMapContract

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

      MAP_CLASSES =
        if RUBY_ENGINE == "ruby"
          [WeakKeyMap, WeakValueMap, WeakMap].freeze
        else
          [].freeze
        end

      def map_classes = MAP_CLASSES

      def setup
        skip "shared weak maps require native ractors" unless RUBY_ENGINE == "ruby"
      end

      def teardown
        Fiber.set_scheduler(nil) if Fiber.respond_to?(:scheduler) && Fiber.scheduler
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

      def test_key_equality_does_not_hold_native_mutex_across_fiber_yield
        skip "native map coordination contract" unless native_weak_maps?

        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        map = WeakValueMap.new
        map[YieldingWeakEqualityKey.new(1, yield_fiber: true)] = :one
        events = []

        Fiber.schedule do
          events << :lookup
          events << map[YieldingWeakEqualityKey.new(2)]
        end
        Fiber.schedule do
          events << :size
          events << map.size
        end
        Fiber.set_scheduler(nil)

        assert_equal [:lookup, :size, nil, 1], events
        assert_operator scheduler.io_wait_calls, :>=, 1
        assert_equal :one, map[YieldingWeakEqualityKey.new(1)]
      end

      def test_key_equality_thread_pass_contention_stress
        map = WeakValueMap.new
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
        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        map = WeakValueMap.new({ key: 1 })
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
        assert_operator scheduler.io_wait_calls, :>=, 1
      end

      def test_recursive_update_mutation_raises_and_releases_the_reservation
        skip "native map coordination contract" unless native_weak_maps?

        MAP_CLASSES.each do |klass|
          map = klass.new({ key: 1 })
          error = assert_raises(ThreadError) do
            map.update(:key) { map[:other] = 9 }
          end

          assert_match(/recursive weak-map access during an update/, error.message)
          assert_equal 1, map[:key]
          refute map.key?(:other)
          assert_equal 2, map.update(:key) { |old| old + 1 }
        end
      end

      def test_unscheduled_sibling_fiber_cannot_wait_for_the_owners_update
        skip "native map coordination contract" unless native_weak_maps?

        MAP_CLASSES.each do |klass|
          map = klass.new({ key: 1 })
          contender = Fiber.new do
            map[:other] = 9
          rescue ThreadError => e
            e
          end
          error = nil

          assert_equal(2, map.update(:key) do |old|
            error = contender.resume
            old + 1
          end)
          assert_kind_of ThreadError, error
          assert_match(/another unscheduled fiber/, error.message)
          refute map.key?(:other)
          assert_equal 3, map[:other] = 3
        end
      end

      def test_wait_does_not_block_a_fiber_scheduler
        iterations = native_weak_maps? ? 1 : 25
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
        skip "native weak maps do not use the owner Ractor" if native_weak_maps?

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

      def test_mutation_from_multiple_ractors
        MAP_CLASSES.each do |klass|
          map = klass.new
          workers = 4.times.map do
            Ractor.new(map) do |shared|
              50.times { shared.upsert(:counter, 1) { |old| old + 1 } }
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

      private

      def native_weak_maps?
        Internal.const_defined?(:NATIVE_WEAK_MAPS, false) && Internal::NATIVE_WEAK_MAPS
      end

      def build_entry(klass, retain:)
        # Build the entry on a disposable native stack. CRuby conservatively
        # scans C stack slots, so a stale VALUE from #[]= can otherwise keep the
        # nominally weak side alive after this Ruby method has returned.
        Thread.new do
          map = klass.new
          key = Ractor.make_shareable(Object.new)
          value = Ractor.make_shareable(Object.new)
          map[key] = value
          [map, retain == :key ? key : value]
        end.value
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
end
