# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "timeout"

module Farce
  class TestBoundedMapLoading < Test
    include Helpers::InternalTestHelpers

    MAP_CLASSES = [
      LRUMap,
      Strict::LRUMap,
      Unshared::LRUMap,
      Local::LRUMap,
      LFUMap,
      Strict::LFUMap,
      Unshared::LFUMap,
      Local::LFUMap
    ].freeze
    UNSHARED_MAP_CLASSES = [Unshared::LRUMap, Unshared::LFUMap].freeze
    SHARED_MAP_CLASSES = [Strict::LRUMap, Strict::LFUMap].freeze

    class CountingKey
      attr_reader :hash_calls

      def initialize(name)
        @name = name
        @hash_calls = 0
      end

      def hash
        # This mutation records how many times the map invokes the hash callback.
        # rubocop:disable-next Security/CompoundHash
        @hash_calls += 1
        @name.hash
      end

      def eql?(other) = CountingKey === other && @name.eql?(other.name)
      def reset = @hash_calls = 0

      protected attr_reader :name
    end

    def test_values_and_required_block
      MAP_CLASSES.each do |klass|
        map = klass.new(max_size: 3)

        assert_nil map.store_if_absent(:nil) { nil }
        assert_nil map.store_if_absent(:nil) { flunk "existing nil entry" }
        assert_raises(LocalJumpError) { map.store_if_absent(:nil) }

        [false, :value].each do |value|
          assert_same value, map.store_if_absent(value) { value }
          assert_same value, map.store_if_absent(value) { flunk "existing entry" }
          assert_raises(LocalJumpError) { map.store_if_absent(value) }
        end
      end
    end

    def test_equal_keys_share_one_loader_and_other_keys_progress
      UNSHARED_MAP_CLASSES.each do |klass|
        map = klass.new(max_size: 3)
        calls = Counter.new
        started = Queue.new
        finish = Queue.new
        loader = Thread.new do
          map.store_if_absent(+"key") do
            calls.increment
            started << true
            finish.pop
            :loaded
          end
        end
        Timeout.timeout(5) { started.pop }
        waiting = Queue.new
        waiter = Thread.new do
          waiting << true
          map.store_if_absent(+"key") do
            calls.increment
            :duplicate
          end
        end
        Timeout.timeout(5) { waiting.pop }

        assert_key_waiter(map, waiter, "equal-key waiter did not block")

        assert_equal :other, map.store_if_absent(:other) { :other }
        finish << true

        assert_equal :loaded, Timeout.timeout(5) { loader.value }
        assert_equal :loaded, Timeout.timeout(5) { waiter.value }
        assert_equal 1, calls.value
      ensure
        [loader, waiter].compact.each { it.kill.join if it.alive? }
      end
    end

    def test_assignment_waits_and_moves_only_after_loader
      [LRUMap, LFUMap].each do |klass|
        map = klass.new(max_size: 2, mode: :move)
        started = Queue.new
        finish = Queue.new
        loader = Thread.new do
          map.store_if_absent(+"key") do
            started << true
            finish.pop
            :loaded
          end
        end
        Timeout.timeout(5) { started.pop }

        value = ModePayload.new(:assigned)
        attempted = Queue.new
        writer = Thread.new do
          attempted << true
          map[+"key"] = value
        end
        Timeout.timeout(5) { attempted.pop }

        assert_key_waiter(map, writer, "same-key writer did not block")

        assert_equal :assigned, value.value
        finish << true

        assert_equal :loaded, Timeout.timeout(5) { loader.value }
        Timeout.timeout(5) { writer.join }

        assert_equal :assigned, map["key"].value
      ensure
        [loader, writer].compact.each { it.kill.join if it.alive? }
      end
    end

    def test_failures_nonlocal_exit_cancellation_and_reentry_release_gate
      UNSHARED_MAP_CLASSES.each do |klass|
        map = klass.new(max_size: 2)

        assert_raises(RuntimeError) { map.store_if_absent(:key) { raise "loader failed" } }
        assert_equal :stopped, map.store_if_absent(:key) { break :stopped }
        refute map.key?(:key)
        assert_raises(ThreadError) do
          map.store_if_absent(:key) { map.store_if_absent(:key) { :nested } }
        end
        assert_raises(ThreadError) do
          map.store_if_absent(:key) { map[:key] = :nested }
        end

        started = Queue.new
        worker = Thread.new do
          map.store_if_absent(:key) do
            started << true
            sleep
          end
        end
        Timeout.timeout(5) { started.pop }
        worker.kill.join

        assert_equal :recovered, map.store_if_absent(:key) { :recovered }
      ensure
        worker&.kill&.join
      end
    end

    def test_hit_uses_one_backend_lookup_and_updates_policy_once
      [Unshared::LRUMap, Unshared::LFUMap].each do |klass|
        key = CountingKey.new(:key)
        map = klass.new({ key => :value }, max_size: 2)
        key.reset

        assert_equal :value, map.store_if_absent(key) { flunk "loader called on hit" }
        assert_equal 1, key.hash_calls
      end

      lru = Unshared::LRUMap.new({ a: 1, b: 2 }, max_size: 2)

      assert_equal 1, lru.store_if_absent(:a) { flunk "loader called on hit" }
      lru[:c] = 3

      assert_equal({ a: 1, c: 3 }, lru.to_h)
      assert_equal [:a, 1], lru.shift

      lfu = Unshared::LFUMap.new({ a: 1, b: 2 }, max_size: 2)

      assert_equal 1, lfu.store_if_absent(:a) { flunk "loader called on hit" }
      lfu[:b]

      assert_equal [:a, 1], lfu.shift

      inserted = Unshared::LFUMap.new(max_size: 2)

      assert_equal 1, inserted.store_if_absent(:a) { 1 }
      inserted[:b] = 2

      assert_equal [:a, 1], inserted.shift
    end

    def test_key_canonicalization_identity_and_aliased_move_value
      [LRUMap, LFUMap, Strict::LRUMap, Strict::LFUMap].each do |klass|
        key = +"key"
        map = klass.new(max_size: 2)

        assert_equal :loaded, map.store_if_absent(key) { :loaded }
        assert_equal :loaded, map["key"]
        assert_predicate map.getkey("key"), :frozen?
      end

      [LRUMap, LFUMap].each do |klass|
        key = +"aliased"
        map = klass.new(max_size: 1, mode: :move)

        assert_equal "aliased", map.store_if_absent(key) { key }
        assert_equal "aliased", map["aliased"]
        assert_predicate map.getkey("aliased"), :frozen?
      end

      UNSHARED_MAP_CLASSES.each do |klass|
        first = "same".dup.freeze
        second = "same".dup.freeze
        calls = 0
        identity = klass.new(max_size: 2, compare_keys_by_identity: true)

        identity.store_if_absent(first) { calls += 1 }
        identity.store_if_absent(second) { calls += 1 }

        assert_equal 2, calls
        assert_equal 2, identity.size
      end
    end

    def test_mode_results_are_wrapped_and_explicit_envelopes_are_preserved
      [LRUMap, LFUMap].each do |klass|
        source = ModePayload.new(:source)
        copy_map = klass.new(max_size: 1, mode: :copy)
        result = copy_map.store_if_absent(:key) { source }

        refute_same source, result
        assert_equal :source, result.value
        assert_equal :source, copy_map[:key].value

        explicit = Envelope.new(ModePayload.new(:explicit), mode: :local)
        envelope_map = klass.new(max_size: 1)

        assert_same explicit, envelope_map.store_if_absent(:key) { explicit }
        assert_same explicit, envelope_map[:key]
      end
    end

    def test_zero_capacity_resize_and_clear_during_loading
      UNSHARED_MAP_CLASSES.each do |klass|
        zero = klass.new(max_size: 0)

        assert_equal :computed, zero.store_if_absent(:key) { :computed }
        assert_empty zero

        resized = klass.new(max_size: 1)

        assert_equal :computed, resized.store_if_absent(:key) {
          resized.max_size = 0
          :computed
        }
        assert_empty resized

        cleared = klass.new({ old: :old }, max_size: 2)

        assert_equal :loaded, cleared.store_if_absent(:key) {
          cleared.clear
          :loaded
        }
        assert_equal({ key: :loaded }, cleared.to_h)
      end
    end

    def test_zero_capacity_equal_key_loaders_run_sequentially
      UNSHARED_MAP_CLASSES.each do |klass|
        map = klass.new(max_size: 0)
        entered = Queue.new
        release = Queue.new
        first = Thread.new do
          map.store_if_absent(:key) do
            entered << :first
            release.pop
            :first
          end
        end

        assert_equal :first, Timeout.timeout(5) { entered.pop }

        waiting = Queue.new
        second = Thread.new do
          waiting << true
          map.store_if_absent(:key) do
            entered << :second
            release.pop
            :second
          end
        end
        Timeout.timeout(5) { waiting.pop }

        assert_key_waiter(map, second, "zero-capacity waiter did not serialize")
        release << true

        assert_equal :first, Timeout.timeout(5) { first.value }
        assert_equal :second, Timeout.timeout(5) { entered.pop }
        release << true

        assert_equal :second, Timeout.timeout(5) { second.value }
        assert_empty map
      ensure
        [first, second].compact.each { it.kill.join if it.alive? }
      end
    end

    def test_canceled_waiter_does_not_split_gate_for_survivor
      UNSHARED_MAP_CLASSES.each do |klass|
        map = klass.new(max_size: 1)
        calls = Counter.new
        started = Queue.new
        finish = Queue.new
        owner = Thread.new do
          map.store_if_absent(:key) do
            calls.increment
            started << true
            finish.pop
            :loaded
          end
        end
        Timeout.timeout(5) { started.pop }

        waiting = Queue.new
        canceled = Thread.new do
          waiting << true

          map.store_if_absent(:key) { flunk "canceled waiter loaded" }
        end
        Timeout.timeout(5) { waiting.pop }

        assert_key_waiter(map, canceled, "waiter did not block")
        canceled.kill.join

        waiting = Queue.new
        survivor = Thread.new do
          waiting << true

          map.store_if_absent(:key) { flunk "surviving waiter loaded" }
        end
        Timeout.timeout(5) { waiting.pop }

        assert_key_waiter(map, survivor, "surviving waiter did not block")
        finish << true

        assert_equal :loaded, Timeout.timeout(5) { owner.value }

        assert_equal :loaded, Timeout.timeout(5) { survivor.value }
        assert_equal 1, calls.value
      ensure
        [owner, canceled, survivor].compact.each { it.kill.join if it.alive? }
      end
    end

    def test_pending_loader_uses_capacity_and_victim_at_commit_time
      UNSHARED_MAP_CLASSES.each do |klass|
        map = klass.new(max_size: 1)
        started = Queue.new
        finish = Queue.new
        loader = Thread.new do
          map.store_if_absent(:loaded) do
            started << true
            finish.pop
            :loaded
          end
        end
        Timeout.timeout(5) { started.pop }
        map[:intermediate] = :intermediate
        finish << true

        assert_equal :loaded, Timeout.timeout(5) { loader.value }
        assert_equal({ loaded: :loaded }, map.to_h)
      ensure
        loader&.kill&.join
      end
    end

    def test_local_thread_scopes_have_independent_maps_and_gates
      [Local::LRUMap, Local::LFUMap].each do |klass|
        map = klass.new(max_size: 1, scope: :thread)

        assert_equal :main, map.store_if_absent(:key) { :main }
        assert_equal :worker, Thread.new { map.store_if_absent(:key) { :worker } }.value
        assert_equal :main, map[:key]
      end
    end

    def test_shared_maps_suppress_loaders_across_ractors
      return unless Internal.native_ractors?

      SHARED_MAP_CLASSES.each do |klass|
        map = klass.new(max_size: 2)
        calls = Counter.new
        start = Queue.new
        workers = 4.times.map do
          Ractor.new(map, calls, start) do |shared, count, barrier|
            barrier.pop
            shared.store_if_absent(:key) do
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
    end

    def test_unscheduled_fiber_cannot_wait_on_same_key
      UNSHARED_MAP_CLASSES.each do |klass|
        map = klass.new(max_size: 2)
        loader = Fiber.new do
          map.store_if_absent(:key) do
            Fiber.yield
            :loaded
          end
        end
        loader.resume

        assert_raises(ThreadError) { map.store_if_absent(:key) { :duplicate } }
        assert_equal :other, map.store_if_absent(:other) { :other }
        assert_equal :loaded, loader.resume
      end
    end

    def test_scheduled_fibers_wait_only_for_their_own_key
      return unless Fiber.respond_to?(:set_scheduler)

      UNSHARED_MAP_CLASSES.each do |klass|
        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        map = klass.new(max_size: 2)
        events = []
        Fiber.schedule do
          map.store_if_absent(:key) do
            events << :loading
            Fiber.scheduler.kernel_sleep(0.01)
            events << :loaded
            :value
          end
        end
        Fiber.schedule { events << map.store_if_absent(:key) { flunk "duplicate loader" } }
        Fiber.schedule { events << map.store_if_absent(:other) { :unrelated } }
        Fiber.set_scheduler(nil)

        assert_equal %i[loading unrelated loaded value], events
      ensure
        Fiber.set_scheduler(nil)
      end
    end

    private

    def assert_key_waiter(map, thread, message)
      locks = map.instance_variable_get(:@key_locks)
      registry = locks&.instance_variable_get(:@registry)
      backend = registry&.instance_variable_get(:@map)
      if backend&.instance_variable_defined?(:@reservations)
        Timeout.timeout(5) do
          loop do
            waiting = backend.send(:with_reservation_index) do
              backend.instance_variable_get(:@reservations).each_value.any? { it.users >= 2 }
            end
            break if waiting
            Thread.pass
          end
        end

        refute thread.join(0), message
      else
        refute thread.join(0.05), message
      end
    end
  end
end
