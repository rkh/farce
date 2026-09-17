# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

return unless RUBY_ENGINE == "jruby"

require_relative "../../setup"
require "weakref"

module Farce
  module Internal
    class JVMBoundedKey
      attr_accessor :raise_from_hash, :raise_from_eql, :callback
      attr_reader :rank, :hash_value

      def initialize(rank, hash_value: 1)
        @rank = rank
        @hash_value = hash_value
      end

      def hash
        callback&.call
        raise "hash callback" if raise_from_hash
        hash_value
      end

      def eql?(other)
        callback&.call
        raise "eql callback" if raise_from_eql
        other.is_a?(JVMBoundedKey) && rank == other.rank
      end
    end

    class JVMHostileReflexiveBoundedKey
      def hash = 17
      def eql?(_other) = raise "identical keys must not call eql?"
    end

    class JVMTruthyBoundedKey
      def initialize(equality) = @equality = equality
      def hash = 19
      def eql?(_other) = @equality
    end

    class JVMFreezingBoundedKey
      attr_accessor :target

      def hash
        target.freeze
        23
      end

      def eql?(_other) = false
    end

    class JVMYieldingBoundedKey
      def initialize
        @yielded = false
      end

      def hash
        unless @yielded
          @yielded = true
          Fiber.yield :inside_hash
        end
        29
      end

      def eql?(other) = equal?(other)
    end

    class JVMBlockingBoundedKey
      def initialize(entered, release)
        @entered = entered
        @release = release
      end

      def hash
        @entered << true
        @release.pop
        31
      end

      def eql?(other) = equal?(other)
    end

    class TestJVMBoundedMap < Test
      MAP_CLASSES = [Internal::LRUMap, Internal::LFUMap].freeze

      def test_boxing_preserves_ruby_key_value_types_and_identity
        MAP_CLASSES.each do |klass|
          map = klass.new(max_size: 8, compare_keys_by_identity: true)
          string_key = +"key"
          string_value = +"value"
          integer = 2**100

          map[string_key] = string_value
          map[integer] = integer
          map[true] = false
          map[nil] = nil

          assert_same string_key, map.getkey(string_key)
          assert_same string_value, map[string_key]
          assert_instance_of String, map[string_key]
          assert_instance_of Integer, map[integer]
          assert_equal integer, map[integer]
          refute map[true]
          assert map.key?(nil)
          assert_nil map[nil]
        end
      end

      def test_canonical_strings_and_exact_identity_mode
        MAP_CLASSES.each do |klass|
          original = +"key"
          equality = klass.new(max_size: 2)
          equality[original] = :value
          stored = equality.getkey("key")
          original.replace("changed")

          assert_equal "key", stored
          refute_same original, stored
          assert_predicate stored, :frozen?
          assert_equal :value, equality["key"]
          assert_nil equality["changed"]

          first = "same".dup.freeze
          second = "same".dup.freeze
          identity = klass.new(max_size: 2, compare_keys_by_identity: true)
          identity[first] = :first
          identity[second] = :second

          assert_equal 2, identity.size
          assert_same first, identity.getkey(first)
          assert_same second, identity.getkey(second)
        end
      end

      def test_collisions_exceptions_and_callback_free_victim_removal
        MAP_CLASSES.each do |klass|
          first = JVMBoundedKey.new(1)
          equal = JVMBoundedKey.new(1)
          second = JVMBoundedKey.new(2)
          map = klass.new(max_size: 2)
          map[first] = :first

          assert_equal :replacement, map[equal] = :replacement
          assert_equal 1, map.size
          assert_same first, map.getkey(equal)

          map[second] = :second
          first.raise_from_eql = true
          second.raise_from_eql = true
          different_hash = JVMBoundedKey.new(3, hash_value: 99)

          assert_equal :third, map[different_hash] = :third
          assert_equal 2, map.size
          first.raise_from_eql = false
          second.raise_from_eql = false
          refute map.key?(second) if klass == Internal::LFUMap

          exploding = JVMBoundedKey.new(4)
          first.raise_from_eql = true
          second.raise_from_eql = true
          assert_raises(RuntimeError) { map[exploding] = :bad }
          first.raise_from_eql = false
          second.raise_from_eql = false

          assert_equal 2, map.size
          assert_equal :third, map[different_hash]
        end
      end

      def test_identical_keys_bypass_eql_and_callbacks_cannot_reenter
        MAP_CLASSES.each do |klass|
          hostile = JVMHostileReflexiveBoundedKey.new
          map = klass.new(max_size: 2)
          map[hostile] = :value

          assert_equal :value, map[hostile]

          recursive = JVMBoundedKey.new(1)
          recursive.callback = -> { map.clear }
          error = assert_raises(ThreadError) { map[recursive] = :recursive }

          assert_match(/recursive bounded map access/, error.message)
          assert_equal 1, map.size
          assert_equal :value, map[hostile]
        end
      end

      def test_eql_results_use_ruby_truthiness
        MAP_CLASSES.each do |klass|
          map = klass.new(max_size: 2)
          truthy = JVMTruthyBoundedKey.new(:yes)

          map[truthy] = :truthy

          assert_equal :truthy, map[JVMTruthyBoundedKey.new(:also_yes)]

          hostile_truthy = Object.new
          hostile_truthy.define_singleton_method(:!) { raise "! must not be called" }
          hostile_map = klass.new(max_size: 2)
          hostile_map[JVMTruthyBoundedKey.new(hostile_truthy)] = :hostile_truthy

          assert_equal :hostile_truthy, hostile_map[JVMTruthyBoundedKey.new(true)]

          falsey_map = klass.new(max_size: 2)
          first_falsey = JVMTruthyBoundedKey.new(nil)
          second_falsey = JVMTruthyBoundedKey.new(nil)
          falsey_map[first_falsey] = :first
          falsey_map[second_falsey] = :second

          assert_equal 2, falsey_map.size
          assert_equal :first, falsey_map[first_falsey]
          assert_equal :second, falsey_map[second_falsey]
        end
      end

      def test_unscheduled_sibling_fiber_is_rejected_during_hash_callback
        MAP_CLASSES.each do |klass|
          map = klass.new(max_size: 1)
          key = JVMYieldingBoundedKey.new
          owner = Fiber.new { map[key] = :value }

          assert_equal :inside_hash, owner.resume
          error = assert_raises(ThreadError) { map.size }
          assert_match(/recursive bounded map access/, error.message)
          assert_equal :value, owner.resume
          assert_equal :value, map[key]
        ensure
          owner.resume if owner&.alive?
        end
      end

      def test_initialization_is_private_transactional_and_one_shot
        MAP_CLASSES.each do |klass|
          map = klass.allocate
          source = Object.new
          source.define_singleton_method(:to_hash) do
            map.send(:initialize, { inner: 1 }, max_size: 2)
            { outer: 2 }
          end

          error = assert_raises(RuntimeError) { map.send(:initialize, source, max_size: 2) }
          assert_match(/already initialized/, error.message)
          assert_equal 1, map[:inner]
          assert_nil map[:outer]
          assert_raises(RuntimeError) { map.send(:initialize, max_size: 2) }

          failed = klass.allocate
          exploding = JVMBoundedKey.new(1)
          failed_entries = { exploding => :bad }
          exploding.raise_from_hash = true
          assert_raises(RuntimeError) do
            failed.send(:initialize, failed_entries, max_size: 1)
          end
          assert_raises(RuntimeError) { failed.size }
          failed.send(:initialize, { good: :good }, max_size: 1)

          assert_equal :good, failed[:good]

          frozen = klass.allocate
          frozen.freeze
          assert_raises(FrozenError) { frozen.send(:initialize, max_size: 1) }
          assert_raises(RuntimeError) { frozen.size }
        end
      end

      def test_freeze_from_initial_hash_prevents_publication
        MAP_CLASSES.each do |klass|
          map = klass.allocate
          key = JVMFreezingBoundedKey.new
          entries = { key => :value }
          key.target = map

          assert_raises(FrozenError) do
            map.send(:initialize, entries, max_size: 1)
          end
          assert_predicate map, :frozen?
          assert_raises(RuntimeError) { map.size }
        end
      end

      def test_async_exception_in_hash_leaves_guard_and_structure_coherent
        MAP_CLASSES.each do |klass|
          map = klass.new(max_size: 2)
          entered = Thread::Queue.new
          release = Thread::Queue.new
          key = JVMBlockingBoundedKey.new(entered, release)
          cancellation = Class.new(StandardError)
          worker = Thread.new do
            map[key] = :bad
          rescue StandardError => e
            e
          end

          entered.pop
          worker.raise(cancellation, "cancel hash")
          release << true

          assert worker.join(5), "cancelled JVM map operation did not finish"
          assert_instance_of cancellation, worker.value
          assert_empty map
          assert_equal :good, map[:good] = :good
        ensure
          release&.push(true)
          worker&.kill if worker&.alive?
        end
      end

      def test_randomized_differential_contract
        { lru: Internal::LRUMap, lfu: Internal::LFUMap }.each do |policy, klass|
          8.times do |seed|
            random = Random.new(seed)
            map = klass.new(max_size: 7)
            model = Helpers::BoundedMapReference.new(policy, max_size: 7)

            600.times do |step|
              key = [nil, false, *(-5..5)].sample(random:)
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

      def test_concurrent_churn_preserves_capacity
        MAP_CLASSES.each do |klass|
          map = klass.new(max_size: 64)
          workers = 8.times.map do |worker|
            Thread.new do
              500.times do |index|
                key = (worker * 10_000) + index
                map[key] = key
                map[key]
              end
            end
          end
          workers.each(&:value)

          assert_equal 64, map.size
          map.each { |key, value| assert_equal key, value }
        ensure
          workers&.each { it.kill if it.alive? }
        end
      end

      def test_long_to_big_integer_transition_preserves_frequency_order
        # The overflow test jar starts new entries at Long::MAX_VALUE - 1. The
        # production jar runs the same policy-ordering scenario from one.
        map = Internal::LFUMap.new(max_size: 2)
        map[:older] = 1
        map[:newer] = 2
        3.times { map[:older] }
        2.times { map[:newer] }

        assert_equal [:newer, 2], map.shift
        assert_equal [:older, 1], map.shift
      end

      def test_table_and_frequency_buckets_stay_bounded_under_churn
        MAP_CLASSES.each do |klass|
          huge = klass.new(max_size: (1 << 63) - 1)

          assert_equal 16, java_field(core(huge), "table").length
          assert_raises(RangeError) { klass.new(max_size: 1 << 63) }

          map = klass.new(max_size: 32)
          10_000.times { |index| map[index] = index }
          storage = core(map)
          table = java_field(storage, "table")

          assert_equal 32, map.size
          assert_operator table.length, :<=, 64

          grown = klass.new(max_size: 512)
          512.times { |index| grown[index] = index }
          grown_storage = core(grown)

          assert_operator java_field(grown_storage, "table").length, :>, 16
          grown.clear

          assert_equal 16, java_field(grown_storage, "table").length

          next unless klass == Internal::LFUMap

          32.times { |rank| rank.times { map[10_000 - 32 + rank] } }
          bucket = java_field(storage, "leastFrequency")
          buckets = 0
          while bucket
            refute_nil java_field(bucket, "leastRecent")
            buckets += 1
            bucket = java_field(bucket, "following")
          end

          assert_operator buckets, :<=, map.size

          map.clear

          assert_nil java_field(storage, "leastFrequency")
        end
      end

      def test_java_storage_keeps_boxed_ruby_objects_reachable
        MAP_CLASSES.each do |klass|
          map, weak_key, weak_value = weakly_referenced_entry(klass)

          3.times { GC.start }

          assert_predicate weak_key, :weakref_alive?
          assert_predicate weak_value, :weakref_alive?
          assert_equal 1, map.size
        end
      end

      private

      def core(map) = map.instance_variable_get(:@state).core

      def weakly_referenced_entry(klass)
        map = klass.new(max_size: 1)
        key = Object.new
        value = Object.new
        weak_key = WeakRef.new(key)
        weak_value = WeakRef.new(value)
        map[key] = value
        [map, weak_key, weak_value]
      end

      def java_field(object, name)
        field = object.java_class.declared_field(name)
        field.accessible = true
        field.value(object)
      end
    end
  end
end
