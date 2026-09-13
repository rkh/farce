# frozen_string_literal: true

require_relative "../../setup"

module Farce
  module Internal
    class TestMap < Test
      include Helpers::InternalTestHelpers

      class ExplodingKey
        def hash = 0
        def eql?(_other) = raise("eql? failed")
      end

      class YieldingEqualityKey
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
          other.is_a?(YieldingEqualityKey) && rank == other.rank
        end
      end

      class ReenteringEqualityKey
        attr_reader :rank

        def initialize(rank, map)
          @rank = rank
          @map = map
          freeze
        end

        def hash = 0

        def eql?(other)
          @map.size
          other.is_a?(ReenteringEqualityKey) && rank == other.rank
        end
      end

      class MutatingEqualityKey
        attr_reader :rank

        def initialize(rank, map)
          @rank = rank
          @map = map
          freeze
        end

        def hash = 0

        def eql?(other)
          @map.update(:callback) { 1 }
          other.is_a?(MutatingEqualityKey) && rank == other.rank
        end
      end

      class HostileIdentityValue
        def initialize(identity_answer)
          @identity_answer = identity_answer
          freeze
        end

        def equal?(_other) = @identity_answer
      end

      def teardown
        Fiber.set_scheduler(nil) if Fiber.respond_to?(:scheduler) && Fiber.scheduler
      end

      def test_defaults_and_initial_mapping
        key = shared_string("key")
        map = Map.new({ key => 1 })

        assert_equal 1, map[key]
        assert map.key?(key)
        assert_equal 1, map.size
        if Internal.native_ractors?
          assert_predicate map, :frozen?
          assert Ractor.shareable?(map)
        end

        refute_predicate map, :compare_keys_by_identity?
        refute_predicate map, :compare_values_by_identity?
      end

      def test_initialization_validation
        assert_raises(TypeError) { Map.new([]) }
        if Internal.native_ractors?
          assert_raises(Ractor::IsolationError) { Map.new({ Object.new => 1 }) }
          assert_raises(Ractor::IsolationError) { Map.new({ Object.new.freeze => [] }) }
        end
        assert_raises(ArgumentError) { Map.new(compare_by_identity: nil) }
        assert_raises(ArgumentError) { Map.new(compare_keys_by_identity: 1) }
        assert_raises(ArgumentError) { Map.new(compare_values_by_identity: :yes) }
        assert_raises(ArgumentError) do
          Map.new(compare_by_identity: HostileIdentityValue.new(true))
        end
      end

      def test_get_set_key_and_delete
        map = Map.new
        key = shared_string("key")

        assert_nil map[key]
        assert_equal 3, map[key] = 3
        assert_equal 3, map[key]
        assert map.key?(key)
        assert_equal 3, map.delete(key)
        refute map.key?(key)
        assert_nil map.delete(key)
      end

      def test_clear
        map = Map.new({ one: 1, two: nil })

        assert_same map, map.clear
        assert_equal 0, map.size
        assert_empty map.keys
        refute map.key?(:one)
        refute map.key?(:two)
        assert_same map, map.clear
        assert_equal 3, map[:three] = 3
        assert_equal({ three: 3 }, map.each.to_h)
      end

      def test_fetch
        map = Map.new({ present: nil })
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

      def test_nil_keys_and_values
        map = Map.new

        assert_nil map[nil] = nil
        assert map.key?(nil)
        assert_nil map[nil]
        assert_nil map.store_if_absent(nil) { flunk "nil key was already present" }
        assert_nil map.swap(nil, 1)
        assert_equal 1, map[nil]
      end

      def test_get_store_and_swap
        map = Map.new({ key: 1 })

        assert_equal 1, map.get(:key, timeout: 0)
        assert_equal 2, map.store(:key, 2, timeout: 0)
        assert_equal 2, map.swap(:key, 3, timeout: 0)
        assert_equal 3, map[:key]
        assert_nil map.swap(:missing, 4)
        assert_equal 4, map[:missing]
      end

      def test_timed_operations_can_fall_back_while_an_atomic_update_is_running
        map = Map.new({ key: 1 })
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
        assert_equal 1, map[:key]
      ensure
        release << true if release
        updater&.join
      end

      def test_wait_until_changed_and_non_nil
        map = Map.new({ key: 1 })
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

      def test_wait_does_not_block_a_fiber_scheduler
        skip "Fiber schedulers are not supported" unless Fiber.respond_to?(:set_scheduler)

        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        map = Map.new
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

      def test_simple_store_contention_does_not_block_a_fiber_scheduler
        return unless RUBY_ENGINE == "ruby"

        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        map = Map.new({ key: 1 })
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

      def test_key_equality_does_not_hold_native_mutex_across_fiber_yield
        return unless RUBY_ENGINE == "ruby"
        skip "Fiber schedulers are not supported" unless Fiber.respond_to?(:set_scheduler)

        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        map = Map.new
        map[YieldingEqualityKey.new(1, yield_fiber: true)] = :one
        events = []

        Fiber.schedule do
          events << :lookup
          events << map[YieldingEqualityKey.new(2)]
        end
        Fiber.schedule do
          events << :size
          events << map.size
        end
        Fiber.set_scheduler(nil)

        assert_equal [:lookup, :size, nil, 1], events
        assert_operator scheduler.io_wait_calls, :>=, 1
        assert_equal :one, map[YieldingEqualityKey.new(1)]
      end

      def test_key_equality_thread_pass_contention_stress
        return unless RUBY_ENGINE == "ruby"

        map = Map.new
        map[YieldingEqualityKey.new(-1, yield_thread: true)] = -1
        threads = 4.times.map do |worker|
          Thread.new do
            30.times do |index|
              rank = (worker * 100) + index
              map[YieldingEqualityKey.new(rank, yield_thread: true)] = rank
            end
          end
        end

        threads.each do |thread|
          assert thread.join(10), "map comparator worker deadlocked"
          thread.value
        end

        assert_equal 121, map.size
      ensure
        threads&.each { |thread| thread.kill if thread.alive? }
      end

      def test_recursive_key_equality_access_raises_without_poisoning_the_map
        return unless RUBY_ENGINE == "ruby"

        map = Map.new
        map[ReenteringEqualityKey.new(1, map)] = :one

        error = assert_raises(ThreadError) { map[ReenteringEqualityKey.new(1, map)] }
        assert_match(/recursive map access/, error.message)
        assert_equal 1, map.size
        assert_equal :plain, map[:plain] = :plain
      end

      def test_key_equality_cannot_deadlock_by_starting_an_exclusive_update
        map = Map.new
        map[MutatingEqualityKey.new(1, map)] = :one
        operation = Thread.new do
          map[MutatingEqualityKey.new(2, map)] = :two
        rescue ThreadError => e
          e
        end

        assert operation.join(5), "recursive equality update deadlocked"
        error = operation.value

        assert_kind_of ThreadError, error
        assert_match(/recursive map access/, error.message)
        assert_equal 1, map.size
        assert_equal :plain, map[:plain] = :plain
      ensure
        operation&.kill
        operation&.join
      end

      def test_recursive_update_mutation_raises_and_releases_the_reservation
        map = Map.new({ key: 1 })
        error = assert_raises(ThreadError) do
          map.update(:key) { map[:key] = 9 }
        end

        assert_match(/recursive map access during an update/, error.message)
        assert_equal({ key: 1 }, map.each.to_h)
        assert_equal 2, map.update(:key) { |old| old + 1 }
      end

      def test_unscheduled_sibling_fiber_cannot_wait_for_the_owners_update
        map = Map.new({ key: 1 })
        owner_thread = Thread.current
        contender = Fiber.new do
          next :different_thread unless Thread.current.equal?(owner_thread)

          map[:key] = 9
        rescue ThreadError => e
          e
        end
        error = nil

        assert_equal(2, map.update(:key) do |old|
          error = contender.resume
          old + 1
        end)
        if error == :different_thread
          assert_equal({ key: 2 }, map.each.to_h)
          assert_equal 3, map[:key] = 3
          return
        end

        assert_kind_of ThreadError, error
        assert_match(/another unscheduled fiber/, error.message)
        assert_equal({ key: 2 }, map.each.to_h)
        assert_equal 3, map[:key] = 3
      end

      def test_unscheduled_owner_check_bypasses_an_overridden_thread_equal
        return if RUBY_ENGINE == "ruby"

        map = Map.new({ key: 1 })
        thread = Thread.current
        singleton = thread.singleton_class
        thread.define_singleton_method(:equal?) { |_other| false }
        primitive_equal = BasicObject.instance_method(:equal?)
        contender = Fiber.new do
          next :different_thread unless primitive_equal.bind_call(Thread.current, thread)

          map[:key] = 9
        rescue ThreadError => e
          e
        end
        error = nil

        Timeout.timeout(2) do
          map.update(:key) do |old|
            error = contender.resume
            old + 1
          end
        end

        return assert_equal({ key: 2 }, map.each.to_h) if error == :different_thread

        assert_kind_of ThreadError, error
        assert_match(/another unscheduled fiber/, error.message)
        assert_equal({ key: 2 }, map.each.to_h)
      ensure
        singleton&.send(:remove_method, :equal?)
      end

      def test_wait_timeouts_and_deletion_to_nil
        map = Map.new({ key: 1 })

        assert_nil map.wait_until_changed(:key, 1, timeout: 0)
        assert_equal :timeout, map.wait_until_non_nil(:missing, timeout: 0) { :timeout }
        deleter = Thread.new do
          sleep 0.01
          map.delete(:key)
        end

        assert_nil map.wait_until_changed(:key, 1, timeout: 1) { flunk "did not observe deletion" }
        deleter.join
      end

      def test_wait_until_changed_uses_configured_value_comparison
        original = shared_string("value")
        equal = shared_string("value")
        by_value = Map.new({ key: original })
        by_identity = Map.new({ key: original }, compare_values_by_identity: true)

        assert_equal :timeout, by_value.wait_until_changed(:key, equal, timeout: 0) { :timeout }
        assert_same original, by_identity.wait_until_changed(:key, equal, timeout: 0)
      end

      def test_wait_and_alias_timeout_validation
        map = Map.new

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

      def test_rejects_unshareable_inputs
        return unless Internal.native_ractors?

        map = Map.new

        assert_raises(Ractor::IsolationError) { map[Object.new] }
        assert_raises(Ractor::IsolationError) { map[Object.new] = 1 }
        assert_raises(Ractor::IsolationError) { map[:key] = Object.new }
        assert_raises(Ractor::IsolationError) { map.store_if_absent(:key) { [] } }
      end

      def test_store_if_absent_distinguishes_nil_from_a_missing_key
        map = Map.new({ existing: nil })
        called = false

        assert_nil map.store_if_absent(:existing) { called = true }
        refute called
        assert_equal 10, map.store_if_absent(:missing, timeout: 0) { 10 }
        assert_equal 10, map[:missing]
      end

      def test_store_if_absent_executes_once_under_contention
        map = Map.new
        calls = 0
        calls_lock = Mutex.new
        threads = 8.times.map do
          Thread.new do
            map.store_if_absent(:key) do
              calls_lock.synchronize { calls += 1 }
              sleep 0.01
              42
            end
          end
        end

        assert_equal [42], threads.map(&:value).uniq
        assert_equal 1, calls
      end

      def test_compare_and_set_by_value
        original = shared_string("value")
        equal = shared_string("value")
        map = Map.new({ item: original })

        assert map.compare_and_set(:item, equal, :replacement, timeout: 0)
        assert_equal :replacement, map[:item]
        refute map.compare_and_set(:missing, nil, :replacement)
      end

      def test_compare_and_set_by_identity
        original = shared_string("value")
        equal = shared_string("value")
        map = Map.new({ item: original }, compare_values_by_identity: true)

        refute map.compare_and_set(:item, equal, :nope)
        assert map.compare_and_set(:item, original, :replacement)
        assert_predicate map, :compare_values_by_identity?
      end

      def test_identity_value_comparison_bypasses_an_overridden_equal
        impostor = HostileIdentityValue.new(true)
        probe = Object.new.freeze
        map = Map.new({ item: impostor }, compare_values_by_identity: true)

        refute map.compare_and_set(:item, probe, :replacement)
        assert map.compare_and_set(:item, impostor, :replacement)

        self_denial = HostileIdentityValue.new(false)
        map = Map.new({ item: self_denial }, compare_values_by_identity: true)

        assert map.compare_and_set(:item, self_denial, :replacement)
      end

      def test_identity_keys
        stored = shared_string("key")
        equal = shared_string("key")
        map = Map.new(compare_keys_by_identity: true)
        map[stored] = 1

        assert_equal 1, map[stored]
        assert_nil map[equal]
        assert_same stored, map.getkey(stored)
        assert_nil map.getkey(equal)
        assert_predicate map, :compare_keys_by_identity?
      end

      def test_getkey_returns_the_stored_key
        stored = shared_string("key")
        equal = shared_string("key")
        map = Map.new({ stored => 1 })

        assert_same stored, map.getkey(equal)
        assert_nil map.getkey(shared_string("missing"))
      end

      def test_iteration
        first = shared_string("first")
        second = shared_string("second")
        expected = { first => 1, second => nil }
        map = Map.new(expected)

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

      def test_upsert
        map = Map.new
        called = false

        assert_equal 3, map.upsert(:key, 3, timeout: 0) { called = true }
        refute called
        assert_equal 4, map.upsert(:key, 0) { |old| old + 1 }
        assert_equal 4, map[:key]
      end

      def test_update_always_calls_the_block
        map = Map.new({ nil_value: nil, counter: 1 })
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
        assert_raises(Ractor::IsolationError) { map.update(:key) { [] } } if Internal.native_ractors?

        assert_equal 12, map.update(:key) { 12 }
      end

      def test_failed_update_does_not_leave_the_map_locked
        map = Map.new({ key: 1 })

        assert_raises(RuntimeError) { map.update(:key) { raise "update failed" } }
        assert_equal 2, map.store(:key, 2, timeout: 0)
        assert_equal 2, map[:key]
      end

      def test_concurrent_updates_are_atomic
        map = Map.new({ counter: 0 })
        threads = 8.times.map do
          Thread.new { 100.times { map.update(:counter) { |old| old + 1 } } }
        end
        threads.each(&:join)

        assert_equal 800, map[:counter]
      end

      def test_many_entries_and_compaction
        map = Map.new
        10_000.times { |index| map["key-#{index}".freeze] = index }

        GC.compact if GC.respond_to?(:compact)

        assert_equal 10_000, map.size
        10_000.times { |index| assert_equal index, map["key-#{index}".freeze] }
      end

      def test_concurrent_upserts_are_atomic
        map = Map.new({ counter: 0 })
        threads = 8.times.map do
          Thread.new { 250.times { map.upsert(:counter, 0) { |old| old + 1 } } }
        end
        threads.each(&:join)

        assert_equal 2_000, map[:counter]
      end

      def test_key_equality_exception_does_not_leave_the_map_locked
        stored = Ractor.make_shareable(ExplodingKey.new)
        probe = Ractor.make_shareable(ExplodingKey.new)
        map = Map.new({ stored => 1 })

        assert_raises(RuntimeError) { map[probe] }
        map[:healthy] = 2

        assert_equal 2, map[:healthy]
      end

      def test_truffleruby_concurrent_map_methods_remain_available
        return unless defined?(TruffleRuby::ConcurrentMap)

        map = Map.new
        waiter = Thread.new { map.wait_until_non_nil(:key, timeout: 1) }

        assert_kind_of TruffleRuby::ConcurrentMap, map
        assert_respond_to map, :compute_if_absent
        assert_respond_to map, :get_and_set
        assert_equal 1, map.compute_if_absent(:key) { 1 }
        assert_equal 1, waiter.value
        assert_equal 1, map.get_and_set(:key, 2)
        assert_equal 2, map[:key]

        identity_map = Map.new(compare_keys_by_identity: true)
        stored = shared_string("identity key")
        equal = shared_string("identity key")

        assert_equal 3, identity_map.compute_if_absent(stored) { 3 }
        assert_equal 3, identity_map[stored]
        assert_nil identity_map[equal]
        assert_same stored, identity_map.getkey(stored)

        pairs = []
        identity_map.each_pair { |key, value| pairs << [key, value] }

        assert_same stored, pairs.fetch(0).fetch(0)
        assert_equal 3, pairs.fetch(0).fetch(1)
      end

      def test_truffleruby_concurrent_map_conditional_methods
        return unless defined?(TruffleRuby::ConcurrentMap)

        map = Map.new({ key: 1 })

        assert_equal 1, map.get_or_default(:key, 0)
        assert_equal 0, map.get_or_default(:missing, 0)
        assert_equal 1, map.replace_if_exists(:key, 2)
        assert map.replace_pair(:key, 2, 3)
        refute map.replace_pair(:key, 2, 4)
        refute map.delete_pair(:key, 4)
        assert map.delete_pair(:key, 3)
        assert_equal map, map.clear
        assert_equal 0, map.size

        original = shared_string("value")
        equal = shared_string("value")
        identity_map = Map.new({ key: original }, compare_values_by_identity: true)

        refute identity_map.delete_pair(:key, equal)
        refute identity_map.replace_pair(:key, equal, :replacement)
        assert identity_map.replace_pair(:key, original, :replacement)
        assert_equal :replacement, identity_map[:key]
      end

      def test_truffleruby_concurrent_map_compute_methods
        return unless defined?(TruffleRuby::ConcurrentMap)

        map = Map.new

        assert_equal 1, map.compute(:key) { |value| value.to_i + 1 }
        assert_equal 2, map.compute_if_present(:key) { |value| value + 1 }
        assert_nil map.compute_if_present(:missing) { flunk "missing key was present" }
        assert_equal 3, map.compute_if_absent(:missing) { 3 }
        assert_equal 6, map.merge_pair(:key, 4) { |value| value + 4 }

        pairs = {}
        map.each_pair { |key, value| pairs[key] = value }

        assert_equal({ key: 6, missing: 3 }, pairs)
      end
    end
  end
end
