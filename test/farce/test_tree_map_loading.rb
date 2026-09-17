# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "timeout"

module Farce
  class TestTreeMapLoading < Test
    include Helpers::InternalTestHelpers

    MAPS = [TreeMap, Strict::TreeMap, Unshared::TreeMap, Local::TreeMap, Unsafe::TreeMap].freeze

    class OrderedKey
      attr_reader :number

      def initialize(number)
        @number = number
        freeze
      end

      def <=>(other)
        raise "comparison failed" if Thread.current[:farce_ordered_key_failure]
        number <=> other.number
      end
    end

    def test_values_and_required_block
      MAPS.each do |klass|
        map = klass.new

        assert_nil map.store_if_absent(-1) { nil }
        assert_nil map.store_if_absent(-1) { flunk "existing nil entry" }
        assert_raises(LocalJumpError) { map.store_if_absent(-1) }
        [false, :value].each_with_index do |value, key|
          assert_same value, map.store_if_absent(key) { value }
          assert_same value, map.store_if_absent(key) { flunk "existing entry" }
          assert_raises(LocalJumpError) { map.store_if_absent(key) }
        end
        assert_raises(LocalJumpError) { map.store_if_absent(99) }
      end
    end

    def test_equivalent_keys_share_loader_and_unrelated_keys_progress
      [TreeMap, Strict::TreeMap, Unshared::TreeMap, Local::TreeMap].each do |klass|
        map = klass.new
        started = Queue.new
        finish = Queue.new
        first = Thread.new do
          map.store_if_absent(1) do
            started << true
            finish.pop
            :loaded
          end
        end
        Timeout.timeout(5) { started.pop }
        second = Thread.new { map.store_if_absent(1.0) { flunk "duplicate loader" } }
        other = Thread.new { map.store_if_absent(2) { :other } }

        assert_equal :other, Timeout.timeout(5) { other.value }
        assert_equal :other, map[2]
        finish << true

        assert_equal :loaded, Timeout.timeout(5) { first.value }
        assert_equal :loaded, Timeout.timeout(5) { second.value }
        assert_equal 1, map.getkey(1.0)
      ensure
        [first, second, other].compact.each { it.kill.join if it.alive? }
      end
    end

    def test_assignment_waits_for_loader
      map = Unshared::TreeMap.new
      started = Queue.new
      finish = Queue.new
      loader = Thread.new do
        map.store_if_absent(1) do
          started << true
          finish.pop
          :loaded
        end
      end
      Timeout.timeout(5) { started.pop }
      writer = Thread.new { map[1.0] = :assigned }
      wait_for_participants(map, 2)

      refute map.key?(1)
      map[2] = :unrelated
      finish << true

      assert_equal :loaded, Timeout.timeout(5) { loader.value }
      assert_equal :assigned, Timeout.timeout(5) { writer.value }
      assert_equal :assigned, map[1]
    ensure
      [loader, writer].compact.each { it.kill.join if it.alive? }
    end

    def test_failure_cancellation_and_nonlocal_exit_release_gate
      map = Unshared::TreeMap.new
      assert_raises(RuntimeError) { map.store_if_absent(1) { raise "loader failed" } }
      assert_equal :stopped, map.store_if_absent(1) { break :stopped }
      refute map.key?(1)
      assert_raises(ThreadError) { map.store_if_absent(1) { map.store_if_absent(1.0) { :nested } } }

      started = Queue.new
      worker = Thread.new do
        map.store_if_absent(1) do
          started << true
          sleep
        end
      end
      Timeout.timeout(5) { started.pop }
      worker.kill.join

      assert_equal :recovered, map.store_if_absent(1) { :recovered }
      assert_predicate map.instance_variable_get(:@key_locks).instance_variable_get(:@entries), :empty?
    ensure
      worker&.kill&.join
    end

    def test_waiter_cancellation_preserves_other_waiters
      map = Unshared::TreeMap.new
      started = Queue.new
      finish = Queue.new
      loader = Thread.new do
        map.store_if_absent(1) do
          started << true
          finish.pop
          :loaded
        end
      end
      Timeout.timeout(5) { started.pop }
      waiter = Thread.new { map.store_if_absent(1.0) { flunk "duplicate loader" } }
      wait_for_participants(map, 2)
      waiter.kill.join
      survivor = Thread.new { map.store_if_absent(1) { flunk "split gate" } }
      finish << true

      assert_equal :loaded, Timeout.timeout(5) { loader.value }
      assert_equal :loaded, Timeout.timeout(5) { survivor.value }
    ensure
      [loader, waiter, survivor].compact.each { it.kill.join if it.alive? }
    end

    def test_key_validation_and_mode_transfer
      called = false
      map = TreeMap.new(mode: :move)
      rejected = Unshared::TreeMap.new

      assert_raises(Ractor::IsolationError) { map.store_if_absent(rejected) { called = true } }
      refute called
      key = +"key"

      assert_equal "key", map.store_if_absent(key) { key }
      assert_equal "key", map.getkey("key")
      assert_predicate map.getkey("key"), :frozen?

      strict = Strict::TreeMap.new
      assert_raises(Ractor::IsolationError) { strict.store_if_absent(1) { rejected } }
      assert_equal :valid, strict.store_if_absent(1) { :valid }
    end

    def test_local_thread_scope_keeps_independent_gates
      map = Local::TreeMap.new(scope: :thread)

      assert_equal :main, map.store_if_absent(1) { :main }
      assert_equal :worker, Thread.new { map.store_if_absent(1) { :worker } }.value
      assert_equal :main, map[1]
    end

    def test_clear_during_loader_can_precede_installation
      map = Unshared::TreeMap.new

      assert_equal :loaded, map.store_if_absent(1) {
        map.clear
        :loaded
      }
      assert_equal :loaded, map[1]
    end

    def test_comparison_failure_retains_coherent_gate_then_reclaims_when_idle
      locks = Internal::OrderedKeyLockMap.new
      one = OrderedKey.new(1)
      two = OrderedKey.new(2)
      locks.synchronize(one) do
        assert_raises(RuntimeError) do
          locks.synchronize(two) { Thread.current[:farce_ordered_key_failure] = true }
        end
        Thread.current[:farce_ordered_key_failure] = false

        assert_equal 2, locks.instance_variable_get(:@entries).size
        assert_equal :retry, locks.synchronize(two) { :retry }
      end
      assert_predicate locks.instance_variable_get(:@entries), :empty?
      assert_equal 0, locks.instance_variable_get(:@participants).get
    ensure
      Thread.current[:farce_ordered_key_failure] = false
    end

    def test_shared_map_suppresses_loaders_across_ractors
      return unless Internal.native_ractors?

      map = Strict::TreeMap.new
      calls = Counter.new
      start = Queue.new
      workers = 4.times.map do |index|
        Ractor.new(map, calls, start, index) do |shared, count, barrier, number|
          barrier.pop
          shared.store_if_absent(number.even? ? 1 : 1.0) do
            count.increment
            sleep 0.02
            :loaded
          end
        end
      end
      4.times { start << true }

      assert_equal [:loaded] * 4, workers.map { ractor_value(it) }.to_a
      assert_equal 1, calls.value
    end

    def test_unscheduled_fiber_cannot_wait_on_loader_in_same_thread
      map = Unshared::TreeMap.new
      loader = Fiber.new do
        map.store_if_absent(1) do
          Fiber.yield
          :loaded
        end
      end
      loader.resume

      assert_raises(ThreadError) { map.store_if_absent(1.0) { :duplicate } }
      assert_equal :other, map.store_if_absent(2) { :other }
      assert_equal :loaded, loader.resume
      assert_equal :loaded, map[1]
    end

    def test_scheduled_fibers_wait_only_for_their_own_key
      return unless Fiber.respond_to?(:set_scheduler)

      scheduler = Helpers::QueueTestScheduler.new
      Fiber.set_scheduler(scheduler)
      map = Unshared::TreeMap.new
      events = []
      Fiber.schedule do
        map.store_if_absent(1) do
          events << :loading
          Fiber.scheduler.kernel_sleep(0.01)
          events << :loaded
          :value
        end
      end
      Fiber.schedule { events << map.store_if_absent(1.0) { flunk "duplicate loader" } }
      Fiber.schedule { events << map.store_if_absent(2) { :unrelated } }
      Fiber.set_scheduler(nil)

      assert_equal %i[loading unrelated loaded value], events
    ensure
      Fiber.set_scheduler(nil) if Fiber.respond_to?(:set_scheduler)
    end

    def test_assignment_canonicalizes_key_before_moving_aliased_value
      map = TreeMap.new(mode: :move)
      key = +"key"
      map[key] = key

      assert_equal "key", map["key"]
      assert_equal "key", map.getkey("key")
    end

    class StringKey < String
      attr_accessor :marker
    end

    def test_canonicalized_subclass_preserves_instance_state
      key = StringKey.new("key")
      key.marker = :preserved
      map = Unshared::TreeMap.new

      assert_equal :loaded, map.store_if_absent(key) {
        key.replace("changed")
        :loaded
      }
      stored = map.getkey("key")

      assert_instance_of StringKey, stored
      assert_equal :preserved, stored.marker
      assert_predicate stored, :frozen?
      refute map.key?("changed")
    end

    private

    def wait_for_participants(map, count)
      locks = map.instance_variable_get(:@key_locks)
      counter = locks.instance_variable_get(:@participants)
      Timeout.timeout(5) { Thread.pass until counter.get >= count }
    end
  end
end
