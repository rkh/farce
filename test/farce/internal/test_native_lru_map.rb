# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

return unless RUBY_ENGINE == "ruby"

require_relative "../../setup"

module Farce
  module Internal
    class NativeLRUCollisionKey
      attr_accessor :raise_from_eql
      attr_reader :rank

      def initialize(rank)
        @rank = rank
        @raise_from_eql = false
      end

      def hash = 1

      def eql?(other)
        raise "eql callback" if raise_from_eql

        other.is_a?(NativeLRUCollisionKey) && rank == other.rank
      end
    end

    class NativeLRUHostileReflexiveKey
      def hash = 23
      def eql?(_other) = raise "identical keys must not call eql?"
    end

    class NativeLRUReentrantKey
      def initialize(rank, callback:)
        @rank = rank
        @callback = callback
      end

      def hash
        @callback.call
        1
      end

      def eql?(other)
        @callback.call
        other.is_a?(NativeLRUReentrantKey) && @rank == other.instance_variable_get(:@rank)
      end
    end

    class NativeLRUFreezingKey
      attr_reader :rank

      def initialize(rank)
        @rank = rank
        freeze
      end

      def hash
        Thread.current[:native_lru_freeze_target]&.freeze if
          Thread.current[:native_lru_freeze_callback] == :hash
        29
      end

      def eql?(other)
        Thread.current[:native_lru_freeze_target]&.freeze if
          Thread.current[:native_lru_freeze_callback] == :eql
        other.is_a?(NativeLRUFreezingKey) && rank == other.rank
      end
    end

    class NativeLRUPublicationReentry
      attr_reader :reentry_rejected

      def initialize(target)
        @target = target
        @reentry_rejected = false
      end

      def freeze
        begin
          @target.send(:initialize, max_size: 1)
        rescue RuntimeError, ThreadError
          @reentry_rejected = true
        end
        super
      end
    end

    class NativeLRUFiberYieldKey
      def hash
        Fiber.scheduler&.kernel_sleep(0.01)
        31
      end

      def eql?(_other) = false
    end

    class NativeLRUFiberResumeKey
      def hash
        Thread.current[:native_lru_contender]&.resume
        37
      end

      def eql?(_other) = false
    end

    class TestNativeLRUMap < Test
      include Helpers::InternalTestHelpers

      MAP_CLASSES = [Internal::LRUMap, Internal::ShareableLRUMap].freeze

      def teardown
        Fiber.set_scheduler(nil) if Fiber.respond_to?(:scheduler) && Fiber.scheduler
        Thread.current[:native_lru_contender] = nil
        Thread.current[:native_lru_freeze_target] = nil
        Thread.current[:native_lru_freeze_callback] = nil
      end

      def test_validation_and_platform_capacity_bound
        MAP_CLASSES.each do |klass|
          assert_raises(ArgumentError) { klass.new }
          assert_raises(TypeError) { klass.new(max_size: 1.0) }
          assert_raises(TypeError) { klass.new(max_size: false) }
          assert_raises(ArgumentError) { klass.new(max_size: -1) }
          assert_raises(ArgumentError) { klass.new(max_size: 1, compare_by_identity: nil) }
          assert_raises(ArgumentError) { klass.new(max_size: 1, compare_keys_by_identity: 1) }
          assert_raises(ArgumentError) { klass.new(max_size: 1, compare_values_by_identity: :yes) }

          maximum = (1 << ([0].pack("J").bytesize * 8)) - 1
          map = klass.new(max_size: maximum)

          assert_equal maximum, map.max_size
          assert_raises(RangeError) { klass.new(max_size: maximum + 1) }
          assert_raises(TypeError) { map.max_size = nil }
          assert_raises(ArgumentError) { map.max_size = -1 }
          assert_raises(TypeError) { map.prune(to: 1.5) }
          assert_raises(ArgumentError) { map.prune(to: -1) }
        end
      end

      def test_basic_lru_protocol_with_nil_and_false
        MAP_CLASSES.each do |klass|
          map = klass.new({ nil => false, false => nil, one: 1 }, max_size: 3)

          assert_equal 3, map.size
          assert_equal map.size, map.length
          refute map[nil]
          assert_nil map[false]
          assert map.key?(false)
          assert_same false, map.getkey(false)
          assert_equal :fallback, map.fetch(:missing, :fallback)
          assert_equal :block, map.fetch(:missing, :block)
          error = assert_raises(KeyError) { map.fetch(:missing) }
          assert_equal :missing, error.key
          assert_same map, error.receiver

          assert_equal 4, map[:four] = 4
          refute map.key?(:one)
          assert_equal [nil, false], map.shift
          assert_equal 2, map.prune(to: 0)
          assert_nil map.shift
          assert_predicate map, :empty?
        end
      end

      def test_accessors_promote_and_observers_do_not
        MAP_CLASSES.each do |klass|
          map = klass.new({ one: 1, two: 2, three: 3 }, max_size: 3)

          assert map.key?(:one)
          assert_same :one, map.getkey(:one)
          assert_equal %i[one two three], map.keys
          assert_equal 1, map[:one]
          assert_equal %i[two three one], map.keys
          assert_equal 2, map.fetch(:two)
          assert_equal %i[three one two], map.keys
          assert_equal 30, map[:three] = 30
          assert_equal %i[one two three], map.keys
          assert_equal [[:one, 1], [:two, 2], [:three, 30]], map.each.to_a
          assert_equal %i[one two three], map.keys
        end
      end

      def test_capacity_change_prune_clear_and_zero_capacity
        MAP_CLASSES.each do |klass|
          zero = klass.new(max_size: 0)

          assert_equal :value, zero[:key] = :value
          assert_empty zero

          map = klass.new({ one: 1, two: 2, three: 3 }, max_size: 3)

          assert_equal 1, map.max_size = 1
          assert_equal [[:three, 3]], map.each.to_a
          assert_equal 4, map.max_size = 4
          map[:four] = 4

          assert_equal 0, map.prune(to: 5)
          assert_equal 1, map.prune(to: 1)
          assert_equal [[:four, 4]], map.each.to_a
          assert_same map, map.clear
          assert_empty map
          assert_equal 4, map.max_size
        end
      end

      def test_string_canonicalization_and_identity
        MAP_CLASSES.each do |klass|
          original = +"key"
          equality = klass.new(max_size: 1)
          equality[original] = :value
          stored = equality.getkey(+"key")

          assert_predicate stored, :frozen?
          refute_same original, stored
          original << "-changed"

          assert_equal :value, equality[+"key"]
        end

        key = +"identity"
        local = Internal::LRUMap.new(max_size: 1, compare_keys_by_identity: true)
        local[key] = :value

        assert_same key, local.getkey(key)
        assert_nil local[+"identity"]
        assert_raises(Ractor::IsolationError) do
          Internal::ShareableLRUMap.new(max_size: 1, compare_keys_by_identity: true)[key] = :value
        end
      end

      def test_prepare_key_returns_a_stable_validated_snapshot
        original = +"key"
        map = Internal::ShareableLRUMap.new(max_size: 1)
        prepared = map.prepare_key(original)

        assert_predicate prepared, :frozen?
        refute_same original, prepared
        original.replace("changed")
        map[prepared] = :value

        assert_equal :value, map["key"]
        assert_raises(Ractor::IsolationError) do
          Internal::ShareableLRUMap
            .new(max_size: 1, compare_keys_by_identity: true)
            .prepare_key(+"identity")
        end
      end

      def test_shareable_storage_validation_and_local_mutable_values
        local_value = Object.new
        local = Internal::LRUMap.new(max_size: 1)
        local[:key] = local_value

        assert_same local_value, local[:key]

        shared = Internal::ShareableLRUMap.new(max_size: 1)
        assert_raises(Ractor::IsolationError) { shared[Object.new] }
        assert_raises(Ractor::IsolationError) { shared[Object.new] = :value }
        assert_raises(Ractor::IsolationError) { shared[:key] = Object.new }
        assert_raises(Ractor::IsolationError) { shared.delete(Object.new) }
        assert_empty shared
      end

      def test_identical_key_bypasses_eql
        key = NativeLRUHostileReflexiveKey.new
        map = Internal::LRUMap.new(max_size: 1)

        map[key] = :one

        assert_equal :one, map[key]
        assert_equal :two, map[key] = :two
        assert_equal :two, map.delete(key)
      end

      def test_callback_failures_and_reentry_leave_storage_intact
        map = Internal::LRUMap.new({ stable: 1 }, max_size: 3)
        exploding = Object.new
        exploding.define_singleton_method(:hash) { raise "hash failed" }

        assert_raises(RuntimeError) { map[exploding] = 2 }
        assert_equal({ stable: 1 }, map.each.to_h)

        recursive = NativeLRUReentrantKey.new(1, callback: -> { map.key?(:stable) })
        assert_raises(ThreadError) { map[recursive] = 2 }
        assert_equal({ stable: 1 }, map.each.to_h)

        first = NativeLRUCollisionKey.new(1)
        map[first] = :first
        first.raise_from_eql = true
        assert_raises(RuntimeError) { map.delete(NativeLRUCollisionKey.new(2)) }
        assert_equal 2, map.size
        assert_equal :first, map.delete(first)
        assert_equal({ stable: 1 }, map.each.to_h)
      end

      def test_victim_operations_do_not_invoke_key_callbacks
        keys = 3.times.map { NativeLRUCollisionKey.new(it) }
        map = Internal::LRUMap.new(max_size: 3)
        keys.each { |key| map[key] = key.rank }

        assert_equal 3, map.size
        keys.each { |key| key.raise_from_eql = true }

        assert_equal [keys[0], 0], map.shift
        assert_equal 1, map.prune(to: 1)
        assert_equal 0, map.max_size = 0
        assert_empty map
        assert_same map, map.clear
      end

      def test_local_freeze_blocks_policy_mutation_but_allows_observation
        map = Internal::LRUMap.new({ one: 1 }, max_size: 2)
        map.freeze

        assert_nil map[:missing]
        assert_equal 1, map[:one]
        assert map.key?(:one)
        assert_same :one, map.getkey(:one)
        assert_equal [:one], map.keys
        assert_raises(FrozenError) { map[:two] = 2 }
        assert_raises(FrozenError) { map.delete(:one) }
        assert_raises(FrozenError) { map.shift }
        assert_raises(FrozenError) { map.prune(to: 0) }
        assert_raises(FrozenError) { map.max_size = 0 }
        assert_raises(FrozenError) { map.clear }
      end

      def test_shared_map_is_mutable_and_shareable_until_logically_frozen
        map = Internal::ShareableLRUMap.new(max_size: 2)

        refute_predicate map, :frozen?
        assert Ractor.shareable?(map)
        assert_equal 1, map[:one] = 1

        map.freeze

        assert_predicate map, :frozen?
        assert_equal 1, map[:one]
        assert_raises(FrozenError) { map[:two] = 2 }
        assert_raises(FrozenError) { map.delete(:one) }
      end

      def test_failed_initialization_can_retry_before_publication
        MAP_CLASSES.each do |klass|
          map = klass.allocate
          assert_raises(ArgumentError) { map.send(:initialize, max_size: -1) }
          assert_same map, map.send(:initialize, max_size: 1)
          assert_empty map
          assert_raises(RuntimeError) { map.send(:initialize, max_size: 1) }
        end
      end

      def test_freezing_to_hash_or_initial_key_callback_prevents_publication
        klass = Internal::ShareableLRUMap

        map = klass.allocate
        source = Object.new
        source.define_singleton_method(:to_hash) do
          map.freeze
          {}
        end
        assert_raises(FrozenError) { map.send(:initialize, source, max_size: 1) }
        assert_raises(RuntimeError) { map.size }

        %i[hash eql].each do |callback|
          map = klass.allocate
          keys = [NativeLRUFreezingKey.new(1), NativeLRUFreezingKey.new(2)]
          Thread.current[:native_lru_freeze_target] = map
          Thread.current[:native_lru_freeze_callback] = callback

          assert_raises(FrozenError) do
            map.send(:initialize, keys.to_h { [it, it.rank] }, max_size: 2)
          end
          assert_raises(RuntimeError) { map.size }
        ensure
          Thread.current[:native_lru_freeze_target] = nil
          Thread.current[:native_lru_freeze_callback] = nil
        end
      end

      def test_publication_rejects_ruby_ivars_and_leaves_safe_state
        map = Internal::ShareableLRUMap.allocate
        metadata = Object.new
        metadata.instance_variable_set(:@values, [1, 2, 3])
        map.instance_variable_set(:@metadata, metadata)

        error = assert_raises(TypeError) { map.send(:initialize, max_size: 1) }

        assert_match(/cannot be published with Ruby instance variables/, error.message)
        refute_predicate metadata, :frozen?
        refute Ractor.shareable?(map)
        assert_raises(RuntimeError) { map.size }
      end

      def test_rejected_preinitialize_ivar_is_not_frozen_or_published
        map = Internal::ShareableLRUMap.allocate
        metadata = NativeLRUPublicationReentry.new(map)
        map.instance_variable_set(:@metadata, metadata)

        assert_raises(TypeError) do
          Timeout.timeout(2) { map.send(:initialize, max_size: 1) }
        end

        refute_predicate metadata, :reentry_rejected
        refute_predicate metadata, :frozen?
        refute Ractor.shareable?(map)
        assert_raises(RuntimeError) { map.size }
      end

      def test_concurrent_initializers_commit_once
        map = Internal::ShareableLRUMap.allocate
        arrived = Thread::Queue.new
        release = Thread::Queue.new
        sources = 2.times.map do |index|
          Object.new.tap do |source|
            source.define_singleton_method(:to_hash) do
              arrived << true
              release.pop
              { index => index }
            end
          end
        end
        threads = sources.map do |source|
          Thread.new do
            map.send(:initialize, source, max_size: 1)
            :initialized
          rescue RuntimeError => e
            e
          end
        end
        2.times { arrived.pop }
        2.times { release << true }
        results = threads.map(&:value)

        assert_equal 1, results.count(:initialized)
        assert_match(/already initialized/, results.grep(RuntimeError).fetch(0).message)
        assert_equal 1, map.size
      ensure
        2.times { release << true } if release
        threads&.each { it.kill.join if it.alive? }
      end

      def test_atomic_first_ractor_visibility
        assert_atomic_ractor_publication(Internal::ShareableLRUMap, iterations: 2_000) do |map|
          map.send(:initialize, max_size: 1)
        end
      end

      def test_concurrent_threads_preserve_capacity_and_entries
        map = Internal::LRUMap.new(max_size: 128)
        workers = 8.times.map do |worker|
          Thread.new do
            500.times do |index|
              key = (worker * 10_000) + index
              map[key] = key
              map[key]
            end
          end
        end
        workers.each do |worker|
          assert worker.join(10), "LRU worker deadlocked"
          worker.value
        end

        assert_equal 128, map.size
        entries = map.each.to_a

        assert_equal entries.length, entries.map(&:first).uniq.length
        entries.each { |key, value| assert_equal key, value }
      ensure
        workers&.each { it.kill.join if it.alive? }
      end

      def test_concurrent_ractor_writers
        map = Internal::ShareableLRUMap.new(max_size: 128)
        workers = 4.times.map do |worker|
          Ractor.new(map, worker) do |shared, prefix|
            300.times do |index|
              key = (prefix * 10_000) + index
              shared[key] = key
              shared[key]
            end
          end
        end
        workers.each { ractor_value(it) }

        assert_equal 128, map.size
        map.each { |key, value| assert_equal key, value }
      end

      def test_scheduler_contention_parks_waiting_fiber
        return unless Fiber.respond_to?(:set_scheduler)

        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        map = Internal::ShareableLRUMap.new(max_size: 2)
        key = NativeLRUFiberYieldKey.new.freeze
        events = []

        Fiber.schedule do
          events << :storing
          map[key] = :value
          events << :stored
        end
        Fiber.schedule do
          events << :waiting
          events << map.size
        end
        Fiber.set_scheduler(nil)

        assert_equal %i[storing waiting stored] + [1], events
        assert_operator scheduler.io_wait_calls, :>=, 1
      ensure
        Fiber.set_scheduler(nil) if Fiber.respond_to?(:scheduler) && Fiber.scheduler
      end

      def test_unscheduled_same_thread_fiber_contention_raises
        map = Internal::ShareableLRUMap.new(max_size: 2)
        Thread.current[:native_lru_contender] = Fiber.new { map.size }
        key = NativeLRUFiberResumeKey.new.freeze

        error = assert_raises(ThreadError) { map[key] = :value }

        assert_match(/another fiber.*same thread/, error.message)
        assert_empty map
        assert_equal :ok, map[:ok] = :ok
      end

      def test_gc_compaction_and_bounded_churn
        MAP_CLASSES.each do |klass|
          map = klass.new(max_size: 32)
          2_000.times do |index|
            value = "value-#{index}"
            value.freeze if klass == Internal::ShareableLRUMap
            map["key-#{index}"] = value
            map["key-#{index}"]
          end

          GC.start
          GC.compact if GC.respond_to?(:compact)

          assert_equal 32, map.size
          map.each do |key, value|
            assert_equal value, map[key]
            assert_match(/\Akey-\d+\z/, key)
          end
        end
      end

      def test_randomized_differential_against_scan_reference
        MAP_CLASSES.each do |klass|
          8.times do |seed|
            random = Random.new(seed)
            map = klass.new(max_size: 7)
            model = Helpers::BoundedMapReference.new(:lru, max_size: 7)

            600.times do |step|
              key = [nil, false, *(-6..6)].sample(random:)
              case random.rand(8)
              when 0, 1
                value = [nil, false, (seed * 1_000) + step].sample(random:)
                expected = model[key] = value
                actual = map[key] = value

                assert expected.eql?(actual)
              when 2

                assert model[key].eql?(map[key])
              when 3

                assert model.delete(key).eql?(map.delete(key))
              when 4
                limit = random.rand(0..10)

                assert_equal(model.max_size = limit, map.max_size = limit)
              when 5
                target = random.rand(0..10)

                assert_equal model.prune(to: target), map.prune(to: target)
              when 6

                assert model.shift.eql?(map.shift)
              when 7
                model.clear
                map.clear
              end

              assert_equal model.max_size, map.max_size
              assert_equal model.size, map.size
              assert_equal model.to_h, map.each.to_h
            end
          end
        end
      end
    end
  end
end
