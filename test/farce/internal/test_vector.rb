# frozen_string_literal: true

require_relative "../../setup"

module Farce
  module Internal
    class TestVector < Test
      include Helpers::InternalTestHelpers

      def teardown
        Fiber.set_scheduler(nil) if Fiber.respond_to?(:scheduler) && Fiber.scheduler
      end

      def test_defaults_and_initial_values
        source = [1, nil, :three]
        vector = Vector.new(source)
        source[0] = :changed

        assert_equal 3, vector.size
        assert_equal 1, vector[0]
        assert_nil vector[1]
        assert_equal :three, vector[-1]
        assert_nil vector[3]
        assert_nil vector[-4]
        refute_predicate vector, :compare_by_identity?
        refute_predicate vector, :frozen?
        return unless Internal.native_ractors?

        assert Ractor.shareable?(vector)
      end

      class FreezingIndex
        def initialize(target, index)
          @target = target
          @index = index
          freeze
        end

        def to_int
          @target.freeze
          @index
        end
      end

      def test_index_conversion_that_freezes_the_vector_cannot_commit
        vector = Vector.new([:original])

        assert_raises(FrozenError) { vector.store(FreezingIndex.new(vector, 0), :replacement) }
        assert_equal :original, vector[0]
      end

      def test_initialization_validation
        assert_raises(TypeError) { Vector.new({}) }
        assert_raises(Ractor::IsolationError) { Vector.new([Object.new]) } if Internal.native_ractors?
        assert_raises(ArgumentError) { Vector.new(compare_by_identity: nil) }
      end

      def test_indexed_assignment_grows_and_supports_negative_indexes
        vector = Vector.new([1, 2])

        assert_equal 3, vector[1] = 3
        assert_equal 4, vector[-1] = 4
        assert_equal 9, vector[4] = 9
        assert_equal 5, vector.size
        assert_equal([1, 4, nil, nil, 9], 5.times.map { |index| vector[index] })
        assert_raises(IndexError) { vector[-6] = 0 }
      end

      def test_indexes_use_implicit_integer_conversion
        coercible = Object.new
        coercible.define_singleton_method(:to_int) { 1 }
        invalid = Object.new
        invalid.define_singleton_method(:to_int) { :one }
        vector = Vector.new([1, 2])

        assert_equal 2, vector[coercible]
        assert_equal 3, vector[coercible] = 3
        assert_raises(TypeError) { vector[Object.new] }
        assert_raises(TypeError) { vector[invalid] }
      end

      def test_get_store_and_clear
        vector = Vector.new

        assert_equal :value, vector.store(2, :value, timeout: 0)
        assert_equal :value, vector.get(2, timeout: 0)
        assert_nil vector.get(1, timeout: 0)
        assert_same vector, vector.clear
        assert_equal 0, vector.size
      end

      def test_push_and_pop
        vector = Vector.new

        assert_same vector, vector.push(:first, timeout: 0)
        assert_same vector, vector.push(:second)
        assert_equal :second, vector.pop(timeout: 0)
        assert_equal :first, vector.pop
        assert_nil vector.pop(timeout: 0)
      end

      def test_swap
        vector = Vector.new([1])

        assert_equal 1, vector.swap(0, 2)
        assert_nil vector.swap(3, 4)
        assert_equal([2, nil, nil, 4], 4.times.map { |index| vector[index] })
      end

      def test_store_if_absent
        vector = Vector.new([:existing, nil])
        calls = 0

        assert_equal :existing, vector.store_if_absent(0) { calls += 1 }
        assert_equal :stored, vector.store_if_absent(1, timeout: 0) {
          calls += 1
          :stored
        }
        initializer = lambda do
          calls += 1
          :grown
        end

        assert_equal :grown, vector.store_if_absent(3, &initializer)
        assert_equal 2, calls
        assert_equal([:existing, :stored, nil, :grown], 4.times.map { |index| vector[index] })
        assert_raises(LocalJumpError) { vector.store_if_absent(0) }
      end

      def test_store_if_absent_supports_negative_indexes
        vector = Vector.new([nil])

        assert_equal :stored, vector.store_if_absent(-1) { :stored }
        assert_equal :stored, vector[-1]
        assert_raises(IndexError) { vector.store_if_absent(-2) { :missing } }
      end

      def test_compare_and_set_by_value
        original = shared_string("value")
        equal = shared_string("value")
        vector = Vector.new([original])

        assert vector.compare_and_set(0, equal, :replacement)
        assert_equal :replacement, vector[0]
        refute vector.compare_and_set(1, nil, :missing)
      end

      def test_compare_and_set_by_identity
        original = shared_string("value")
        equal = shared_string("value")
        vector = Vector.new([original], compare_by_identity: true)

        refute vector.compare_and_set(0, equal, :nope)
        assert vector.compare_and_set(0, original, :replacement)
        assert_predicate vector, :compare_by_identity?
      end

      def test_upsert_uses_initial_for_nil_and_calls_block_for_a_value
        vector = Vector.new([nil, 2])
        called = false

        assert_equal 1, vector.upsert(0, 1) { called = true }
        refute called
        assert_equal 3, vector.upsert(1, 0) { |old| old + 1 }
        assert_equal 4, vector.upsert(3, 4) { called = true }
        refute called
        assert_equal([1, 3, nil, 4], 4.times.map { |index| vector[index] })
        assert_raises(LocalJumpError) { vector.upsert(0, 0) }
      end

      def test_update_always_calls_the_block
        vector = Vector.new([1, nil])
        seen = []

        assert_equal 2, vector.update(0) { |old|
          seen << old
          old + 1
        }
        assert_equal :nil_slot, vector.update(1) { |old|
          seen << old
          :nil_slot
        }
        assert_equal :missing, vector.update(4) { |old|
          seen << old
          :missing
        }
        assert_equal [1, nil, nil], seen
        assert_equal([2, :nil_slot, nil, nil, :missing], 5.times.map { |index| vector[index] })
        assert_raises(LocalJumpError) { vector.update(0) }
      end

      def test_update_supports_negative_indexes
        vector = Vector.new([1, 2])

        assert_equal 3, vector.update(-1) { |old| old + 1 }
        assert_equal 3, vector[-1]
        assert_raises(IndexError) { vector.update(-3) { 0 } }
      end

      def test_failed_update_does_not_grow_or_poison_the_vector
        vector = Vector.new([1])

        if Internal.native_ractors?
          assert_raises(Ractor::IsolationError) { vector.update(3) { Object.new } }
          assert_equal 1, vector.size
        end
        assert_raises(RuntimeError) { vector.update(3) { raise "boom" } }
        assert_equal 1, vector.size
        assert_equal 2, vector.update(0) { |old| old + 1 }
      end

      def test_failed_update_wakes_a_waiting_mutation
        vector = Vector.new([1])
        entered = ::Queue.new
        release = ::Queue.new
        updater = Thread.new do
          vector.update(0) do
            entered << true
            release.pop
            raise "boom"
          end
        rescue StandardError => e
          e
        end
        entered.pop
        writer = Thread.new { vector.store(0, 2, timeout: 1) }
        sleep 0.01

        release << true

        assert_instance_of RuntimeError, updater.value
        assert_equal 2, writer.value
        assert_equal 2, vector[0]
      end

      def test_update_is_atomic_under_contention
        vector = Vector.new([0])
        threads = 8.times.map do
          Thread.new { 250.times { vector.update(0) { |old| old + 1 } } }
        end
        threads.each(&:join)

        assert_equal 2_000, vector[0]
      end

      def test_upsert_is_atomic_under_contention
        vector = Vector.new([0])
        threads = 8.times.map do
          Thread.new { 250.times { vector.upsert(0, 0) { |old| old + 1 } } }
        end
        threads.each(&:join)

        assert_equal 2_000, vector[0]
      end

      def test_store_if_absent_executes_once_under_contention
        vector = Vector.new
        calls = 0
        calls_lock = Mutex.new
        threads = 8.times.map do
          Thread.new do
            vector.store_if_absent(2) do
              calls_lock.synchronize { calls += 1 }
              sleep 0.01
              42
            end
          end
        end

        assert_equal [42], threads.map(&:value).uniq
        assert_equal 1, calls
        assert_equal 42, vector[2]
      end

      def test_failed_store_if_absent_does_not_grow_or_poison_the_vector
        vector = Vector.new([1])

        assert_raises(RuntimeError) { vector.store_if_absent(3) { raise "boom" } }
        assert_equal 1, vector.size
        assert_equal 7, vector.store_if_absent(3) { 7 }
        assert_equal 4, vector.size
      end

      def test_updates_from_multiple_ractors
        return unless Internal.native_ractors?

        vector = Vector.new([0])
        workers = 4.times.map do
          Ractor.new(vector) do |shared|
            250.times { shared.upsert(0, 0) { |old| old + 1 } }
          end
        end
        workers.each { |worker| ractor_value(worker) }

        assert_equal 1_000, vector[0]
      end

      def test_store_if_absent_executes_once_across_ractors
        return unless Internal.native_ractors?

        vector = Vector.new
        calls = Counter.new
        workers = 4.times.map do
          Ractor.new(vector, calls) do |shared, call_count|
            shared.store_if_absent(0) do
              call_count.increment
              Thread.pass
              42
            end
          end
        end

        assert_equal [42], workers.map { |worker| ractor_value(worker) }.uniq
        assert_equal 1, calls.value
        assert_equal 42, vector[0]
      end

      def test_timeout_while_an_atomic_update_is_in_progress
        vector = Vector.new([1])
        entered = ::Queue.new
        release = ::Queue.new
        updater = Thread.new do
          vector.upsert(0, 0) do |old|
            entered << true
            release.pop
            old + 1
          end
        end
        entered.pop

        assert_nil vector.get(0, timeout: 0)
        refute vector.store(0, 3, timeout: 0)
        refute vector.push(3, timeout: 0)
        assert_nil vector.pop(timeout: 0)
        refute vector.compare_and_set(0, 1, 3, timeout: 0)
        assert_nil vector.upsert(0, 0, timeout: 0) { |old| old + 1 }
        store_if_absent_called = false
        update_called = false

        assert_nil vector.store_if_absent(1, timeout: 0) { store_if_absent_called = true }
        assert_nil vector.update(0, timeout: 0) { update_called = true }
        refute store_if_absent_called
        refute update_called
      ensure
        release << true if release
        updater&.join
      end

      def test_wait_until_changed
        vector = Vector.new([:initial])
        waiter = Thread.new { vector.wait_until_changed(0, :initial, timeout: 1) }
        sleep 0.01

        vector[0] = :changed

        assert_equal :changed, waiter.value
        assert_nil vector.wait_until_changed(0, :changed, timeout: 0)
      end

      def test_wait_until_non_nil
        vector = Vector.new
        waiter = Thread.new { vector.wait_until_non_nil(2, timeout: 1) }
        sleep 0.01

        vector[2] = :ready

        assert_equal :ready, waiter.value
        assert_nil Vector.new.wait_until_non_nil(0, timeout: 0)
      end

      def test_wait_does_not_block_a_fiber_scheduler
        return if RUBY_ENGINE == "truffleruby"
        return unless Fiber.respond_to?(:set_scheduler)

        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        vector = Vector.new
        events = []

        Fiber.schedule do
          events << :waiting
          events << vector.wait_until_non_nil(0)
        end
        Fiber.schedule do
          events << :storing
          vector[0] = :value
        end
        Fiber.set_scheduler(nil)

        assert_equal %i[waiting storing value], events
        assert_operator scheduler.io_wait_calls, :>=, 1
      ensure
        Fiber.set_scheduler(nil) if Fiber.respond_to?(:scheduler) && Fiber.scheduler
      end

      def test_update_contention_does_not_block_a_fiber_scheduler
        return if RUBY_ENGINE == "truffleruby"
        return unless Fiber.respond_to?(:set_scheduler)

        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        vector = Vector.new([1])
        events = []

        Fiber.schedule do
          events << :updating
          vector.update(0) do |old|
            Fiber.scheduler.kernel_sleep(0.01)
            events << :update_finished
            old + 1
          end
        end
        Fiber.schedule do
          events << :store_waiting
          vector.store(0, 3)
          events << :stored
        end
        Fiber.set_scheduler(nil)

        assert_equal %i[updating store_waiting update_finished stored], events
        assert_equal 3, vector[0]
        assert_operator scheduler.io_wait_calls, :>=, 1
      ensure
        Fiber.set_scheduler(nil) if Fiber.respond_to?(:scheduler) && Fiber.scheduler
      end

      def test_rejects_unshareable_values
        return unless Internal.native_ractors?

        vector = Vector.new

        assert_raises(Ractor::IsolationError) { vector.push(Object.new) }
        assert_raises(Ractor::IsolationError) { vector[0] = Object.new }
        assert_raises(Ractor::IsolationError) { vector.swap(0, Object.new) }
        assert_raises(Ractor::IsolationError) { vector.store_if_absent(2) { Object.new } }
        assert_equal 0, vector.size
        vector[0] = 1
        assert_raises(Ractor::IsolationError) { vector.upsert(0, 1) { Object.new } }
      end

      def test_invalid_timeouts
        vector = Vector.new

        assert_raises(ArgumentError) { vector.get(0, timeout: -1) }
        assert_raises(ArgumentError) { vector.push(1, timeout: Float::INFINITY) }
        assert_raises(ArgumentError) { vector.store_if_absent(0, timeout: Float::NAN) { 1 } }
      end

      def test_many_values_and_compaction
        vector = Vector.new
        10_000.times { |index| vector.push("value-#{index}".freeze) }

        GC.compact if GC.respond_to?(:compact)

        assert_equal 10_000, vector.size
        10_000.times { |index| assert_equal "value-#{index}", vector[index] }
      end
    end
  end
end
