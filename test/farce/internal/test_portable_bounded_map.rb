# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../../setup"
require "farce/engine/shared/portable_bounded_map"

module Farce
  module Internal
    class TestPortableBoundedMap < Test
      class LRUMap < Farce::Abstract::LRUMap
        private

        def new_bounded_map(...) = PortableLRUMap.new(...)

        def new_key_locks(compare_keys_by_identity:)
          KeyLockMap.new(registry_class: Farce::Unshared::Map, compare_keys_by_identity:)
        end
      end

      class LFUMap < Farce::Abstract::LFUMap
        private

        def new_bounded_map(...) = PortableLFUMap.new(...)

        def new_key_locks(compare_keys_by_identity:)
          KeyLockMap.new(registry_class: Farce::Unshared::Map, compare_keys_by_identity:)
        end
      end

      class PreparingLRUMap < LRUMap
        attr_reader :preparations

        def initialize(...)
          @preparations = []
          super
        end

        private

        def prepare_key(key)
          @preparations << [:key, key]
          -key
        end

        def wrap_value(value)
          @preparations << [:value, value]
          value
        end
      end

      class ReentrantKey
        attr_accessor :map

        def initialize(rank)
          @rank = rank
        end

        def hash = 1

        def eql?(other)
          map&.key?(:recursive)
          other.is_a?(ReentrantKey) && @rank == other.instance_variable_get(:@rank)
        end
      end

      class CollisionKey
        attr_accessor :raise_from_eql
        attr_reader :rank

        def initialize(rank)
          @rank = rank
          @raise_from_eql = false
        end

        def hash = 1

        def eql?(other)
          raise "eql during eviction" if raise_from_eql
          other.is_a?(CollisionKey) && rank == other.rank
        end
      end

      class ConvertibleHashKey
        HashValue = Data.define(:value) do
          def to_int = value
        end

        attr_reader :rank

        def initialize(rank)
          @rank = rank
        end

        def hash = HashValue.new(19)
        def eql?(other) = other.is_a?(ConvertibleHashKey) && rank == other.rank
      end

      class HostileReflexiveKey
        def hash = 23
        def eql?(_other) = raise "eql? must not be called for an identical key"
      end

      class FreezingKey
        attr_accessor :target
        attr_reader :rank

        def initialize(rank)
          @rank = rank
        end

        def hash = 29

        def eql?(other)
          target&.freeze
          other.is_a?(FreezingKey) && rank == other.rank
        end
      end

      class InterruptingLRUMap < PortableLRUMap
        attr_accessor :interrupt_on

        private

        def policy_commit_access(...)
          super
          interrupt!(:access)
        end

        def policy_commit_insert(...)
          super
          interrupt!(:insert)
        end

        def policy_remove(...)
          super
          interrupt!(:remove)
        end

        def interrupt!(operation)
          return unless interrupt_on == operation
          self.interrupt_on = nil
          target = Thread.current
          Thread.new { target.raise(Interrupt) }.join
        end
      end

      class InterruptingInitializeLRUMap < PortableLRUMap
        private

        def initialize_policy
          super
          target = Thread.current
          Thread.new { target.raise(Interrupt) }.join
        end
      end

      MAP_CLASSES = [LRUMap, LFUMap].freeze
      BACKEND_CLASSES = [PortableLRUMap, PortableLFUMap].freeze

      def test_abstract_contract_and_capacity_validation
        MAP_CLASSES.each do |klass|
          map = klass.new({ one: 1, two: 2, three: 3 }, max_size: 2)

          assert_kind_of Abstract::BoundedMap, map
          assert_equal 2, map.max_size
          assert_equal 2, map.size
          assert_raises(TypeError) { klass.new(max_size: 1.0) }
          assert_raises(TypeError) { klass.new(max_size: false) }
          assert_raises(ArgumentError) { klass.new(max_size: -1) }
          assert_raises(ArgumentError) { klass.new(max_size: 1, compare_by_identity: nil) }
          assert_raises(ArgumentError) { klass.new(max_size: 1, compare_keys_by_identity: 1) }
          assert_raises(ArgumentError) { klass.new(max_size: 1, compare_values_by_identity: :yes) }
          assert_raises(TypeError) { map.max_size = 1.5 }
          assert_raises(ArgumentError) { map.max_size = -1 }
          assert_raises(TypeError) { map.prune(to: nil) }
          assert_raises(ArgumentError) { map.prune(to: -1) }
        end
      end

      def test_initialization_is_one_shot_and_published_atomically
        BACKEND_CLASSES.each do |klass|
          map = klass.allocate

          assert_raises(RuntimeError) { map.size }
          map.send(:initialize, max_size: 1)

          assert_equal 1, map.max_size
          assert_raises(RuntimeError) { map.send(:initialize, max_size: 2) }

          frozen = klass.allocate.freeze
          assert_raises(FrozenError) { frozen.send(:initialize, max_size: 1) }
        end

        interrupted = InterruptingInitializeLRUMap.allocate

        assert_raises(Interrupt) { interrupted.send(:initialize, max_size: 1) }
        assert_empty interrupted
        assert_equal :value, interrupted[:key] = :value
        assert_raises(RuntimeError) { interrupted.send(:initialize, max_size: 2) }
      end

      def test_reinitialization_during_suspended_hash_callback_is_rejected
        BACKEND_CLASSES.each do |klass|
          map = klass.new(max_size: 1)
          key = Object.new
          yielded = false
          key.define_singleton_method(:hash) do
            unless yielded
              yielded = true
              Fiber.yield :inside_hash
            end
            19
          end
          owner = Fiber.new { map[key] = :value }

          assert_equal :inside_hash, owner.resume
          error = assert_raises(RuntimeError) { map.send(:initialize, max_size: 2) }
          assert_match(/already initialized/, error.message)
          assert_equal :value, owner.resume
          assert_equal :value, map[key]
        ensure
          owner.resume if owner&.alive?
        end
      end

      def test_zero_capacity_prepares_key_before_value_without_retaining_entry
        key = +"key"
        map = PreparingLRUMap.new(max_size: 0)

        assert_equal :value, map[key] = :value
        assert_equal [[:key, key], %i[value value]], map.preparations
        assert_empty map
        assert_equal 0, map.max_size
      end

      def test_fetch_uses_original_key_for_fallback_and_error
        key = +"missing"
        map = PreparingLRUMap.new(max_size: 1)

        assert_same key, map.fetch(key) { it }
        error = assert_raises(KeyError) { map.fetch(key) }
        assert_same key, error.key
        assert_same map, error.receiver
      end

      def test_prepare_key_returns_a_stable_canonical_key
        original = +"key"
        backend = PortableLRUMap.new(max_size: 1)
        prepared = backend.prepare_key(original)

        assert_predicate prepared, :frozen?
        refute_same original, prepared
        original.replace("changed")
        backend[prepared] = :value

        assert_equal :value, backend["key"]
      end

      def test_crud_nil_false_and_enumeration_protocol
        MAP_CLASSES.each do |klass|
          map = klass.new(max_size: 3)

          assert_nil map[:missing]
          assert_nil(map[:nil] = nil)
          result = map[:false_value] = false

          refute result
          assert map.key?(:nil)
          assert_nil map.fetch(:nil)
          refute map.fetch(:false_value)
          assert_equal :default, map.fetch(:missing, :default)
          assert_equal :fallback, map.fetch(:missing) { :fallback } # rubocop:disable Style/RedundantFetchBlock
          assert_equal %i[false_value nil], map.keys.sort
          assert_includes map.values, nil
          assert_includes map.values, false
          assert_equal({ nil: nil, false_value: false }, map.to_h)
          assert_instance_of Enumerator, map.each
          assert_instance_of Enumerator, map.each_key
          assert_instance_of Enumerator, map.each_value
          assert_equal 2, map.length
          assert_same map, map.clear
          assert_empty map
        end
      end

      def test_enumeration_snapshot_and_fetch_fallback_run_outside_mutex
        MAP_CLASSES.each do |klass|
          map = klass.new({ one: 1, two: 2 }, max_size: 3)
          visited = []

          result = map.each do |key, value|
            visited << [key, value]
            map[:three] = 3
          end

          assert_same map, result
          assert_equal({ one: 1, two: 2 }, visited.to_h)
          fetched = map.fetch(:missing) do
            map[:four] = 4
            map.size
          end

          assert_equal 3, fetched
        end
      end

      def test_canonical_string_and_identity_keys
        MAP_CLASSES.each do |klass|
          original = +"key"
          map = klass.new(max_size: 2)

          map[original] = :value
          stored = map.getkey(+"key")

          refute_same original, stored
          assert_predicate stored, :frozen?
          original.replace("changed")

          assert_equal :value, map[+"key"]

          identity = +"identity"
          identity_map = klass.new(max_size: 2, compare_by_identity: true)
          identity_map[identity] = :value

          assert_same identity, identity_map.getkey(identity)
          assert_nil identity_map[+"identity"]
          assert_predicate identity_map, :compare_keys_by_identity?
          assert_predicate identity_map, :compare_values_by_identity?
        end
      end

      def test_equal_update_retains_canonical_key
        MAP_CLASSES.each do |klass|
          first = +"key"
          second = +"key"
          map = klass.new(max_size: 2)

          map[first] = :first
          stored = map.getkey(second)
          map[second] = :second

          assert_same stored, map.getkey(+"key")
          assert_equal :second, map[+"key"]
          assert_equal 1, map.size
        end
      end

      def test_identical_key_bypasses_equality_callback
        MAP_CLASSES.each do |klass|
          key = HostileReflexiveKey.new
          map = klass.new(max_size: 1)
          map[key] = :value

          assert_equal :value, map[key]
          assert_same key, map.getkey(key)
          assert_equal :value, map.delete(key)
        end
      end

      def test_hash_results_use_ruby_to_int_coercion
        MAP_CLASSES.each do |klass|
          stored = ConvertibleHashKey.new(1)
          probe = ConvertibleHashKey.new(1)
          map = klass.new(max_size: 1)

          map[stored] = :value

          assert_equal :value, map[probe]
          assert_same stored, map.getkey(probe)
        end
      end

      def test_callback_freeze_prevents_pending_mutation
        MAP_CLASSES.each do |klass|
          stored = FreezingKey.new(1)
          probe = FreezingKey.new(1)
          map = klass.new({ stored => :original }, max_size: 1)
          stored.target = map.instance_variable_get(:@map)

          assert_raises(FrozenError) { map[probe] = :replacement }
          assert_equal({ stored => :original }, map.to_h)
        end
      end

      def test_capacity_growth_shrink_prune_shift_and_clear
        MAP_CLASSES.each do |klass|
          map = klass.new({ one: 1, two: 2, three: 3 }, max_size: 3)

          assert_equal 5, map.max_size = 5
          assert_equal 3, map.size
          assert_equal 2, map.max_size = 2
          assert_equal 2, map.size
          assert_equal 0, map.prune(to: 8)
          assert_equal 1, map.prune(to: 1)
          assert_equal 1, map.size
          assert_equal 1, map.prune(to: 0)
          assert_nil map.shift
          assert_equal 2, map.max_size
          map[:new] = 4

          assert_equal [:new, 4], map.shift
          map[:last] = 5
          map.clear

          assert_equal 2, map.max_size
        end
      end

      def test_access_and_observation_semantics
        accessors = [
          ->(map) { map[:a] },
          ->(map) { map.fetch(:a) },
          ->(map) { map.assoc(:a) },
          ->(map) { map.dig(:a, :value) },
          ->(map) { map.values_at(:a) },
          ->(map) { map.fetch_values(:a) }
        ]
        MAP_CLASSES.each do |klass|
          accessors.each do |access|
            map = klass.new({ a: { value: 1 }, b: 2 }, max_size: 2)
            access.call(map)
            map[:c] = 3

            assert map.key?(:a)
            refute map.key?(:b)
          end
        end

        # rubocop:disable-next Style/SymbolProc
        observers = [
          ->(map) { map.key?(:a) },
          ->(map) { map.getkey(:a) },
          ->(map) { map.keys },
          ->(map) { map.values },
          ->(map) { map.each.to_a },
          ->(map) { map.each_key.to_a },
          ->(map) { map.each_value.to_a },
          ->(map) { map.to_h },
          ->(map) { map.inspect },
          ->(map) { map.size },
          ->(map) { map.max_size }
        ]
        MAP_CLASSES.each do |klass|
          observers.each do |observe|
            map = klass.new({ a: 1, b: 2 }, max_size: 2)
            observe.call(map)
            map[:c] = 3

            refute map.key?(:a)
            assert map.key?(:b)
          end
        end
      end

      def test_lru_replacement_promotes_and_missing_fetch_does_not
        map = LRUMap.new({ a: 1, b: 2 }, max_size: 2)
        map[:a] = 1
        map.fetch(:missing, nil)
        map[:c] = 3

        assert_equal({ a: 1, c: 3 }, map.to_h)
      end

      def test_lfu_frequency_ties_replacement_and_always_admit
        map = LFUMap.new({ a: 1, b: 2 }, max_size: 2)
        3.times { map[:a] }
        2.times { map[:b] }
        map[:c] = 3

        assert map.key?(:a)
        refute map.key?(:b)
        assert map.key?(:c)

        tie = LFUMap.new({ a: 1, b: 2 }, max_size: 2)
        tie[:a]
        tie[:b]
        tie[:c] = 3

        refute tie.key?(:a)
        assert tie.key?(:b)

        replacement = LFUMap.new({ a: 1, b: 2 }, max_size: 2)
        replacement[:a] = 9
        replacement[:c] = 3

        assert_equal({ a: 9, c: 3 }, replacement.to_h)
      end

      def test_callback_reentry_raises_without_corrupting_entries
        MAP_CLASSES.each do |klass|
          stored = ReentrantKey.new(1)
          probe = ReentrantKey.new(1)
          map = klass.new(max_size: 2)
          map[stored] = :stored
          stored.map = map

          assert_raises(ThreadError) { map[probe] }
          stored.map = nil

          assert_equal :stored, map[probe]
          assert_equal 1, map.size
        end
      end

      def test_known_victim_removal_never_calls_colliding_key_equality
        MAP_CLASSES.each do |klass|
          %i[shift prune resize].each do |operation|
            protected_key = CollisionKey.new(:protected)
            victim = CollisionKey.new(:victim)
            map = klass.new(max_size: 2)
            map[protected_key] = :protected
            map[victim] = :victim
            map[protected_key]
            protected_key.raise_from_eql = true

            case operation
            when :shift
              pair = map.shift

              assert_same victim, pair.first
              assert_equal :victim, pair.last
            when :prune

              assert_equal 1, map.prune(to: 1)
            when :resize

              assert_equal 1, map.max_size = 1
            end

            assert_equal 1, map.size
            protected_key.raise_from_eql = false

            assert_same protected_key, map.getkey(protected_key)
            assert_equal :protected, map[protected_key]
          end
        end
      end

      def test_equality_failure_during_delete_preserves_structure
        MAP_CLASSES.each do |klass|
          first = CollisionKey.new(:first)
          second = CollisionKey.new(:second)
          map = klass.new({ first => 1, second => 2 }, max_size: 2)
          first.raise_from_eql = true

          assert_raises(RuntimeError) { map.delete(second) }
          assert_equal 2, map.size
          first.raise_from_eql = false

          assert_equal({ first => 1, second => 2 }, map.to_h)
        end
      end

      def test_async_interrupt_is_deferred_until_structural_commit_finishes
        map = InterruptingLRUMap.new(max_size: 2)
        map[:a] = 1
        map[:b] = 2
        map.interrupt_on = :insert

        assert_raises(Interrupt) { map[:c] = 3 }
        assert_equal({ b: 2, c: 3 }, map.each.to_h)

        map.interrupt_on = :access
        assert_raises(Interrupt) { map[:b] }
        assert_equal [:c, 3], map.shift

        map.interrupt_on = :remove
        assert_raises(Interrupt) { map.delete(:b) }
        assert_empty map
      end

      def test_threaded_operations_preserve_capacity
        MAP_CLASSES.each do |klass|
          map = klass.new(max_size: 8)
          threads = 4.times.map do |thread|
            Thread.new do
              500.times do |index|
                key = ((thread * 500) + index) % 16
                map[key] = index
                map[key]
                map.delete((key + 7) % 16) if (index % 11).zero?
              end
            end
          end
          threads.each(&:join)

          assert_operator map.size, :<=, map.max_size
          assert_equal map.size, map.to_h.size
        end
      end

      def test_random_operations_match_independent_reference_model
        { lru: LRUMap, lfu: LFUMap }.each do |policy, klass|
          random = Random.new(12_345)
          map = klass.new(max_size: 5)
          reference = Helpers::BoundedMapReference.new(policy, max_size: 5)
          keys = [nil, false, 0, 1, 2, 3, 4, 5]
          values = [nil, false, 0, 1, 2, 3, 4]

          2_000.times do
            key = keys.sample(random:)
            value = values.sample(random:)
            case random.rand(11)
            when 0, 1, 2
              expected = reference[key]
              actual = map[key]

              assert_identical expected, actual
            when 3, 4
              expected = reference[key] = value
              actual = map[key] = value

              assert_identical expected, actual
            when 5
              expected = reference.delete(key)
              actual = map.delete(key)

              assert_identical expected, actual
            when 6
              limit = random.rand(7)

              assert_equal(reference.max_size = limit, map.max_size = limit)
            when 7
              target = random.rand(7)

              assert_equal reference.prune(to: target), map.prune(to: target)
            when 8
              expected = reference.shift
              actual = map.shift
              if expected
                assert_identical expected.first, actual.first
                assert_identical expected.last, actual.last
              else
                assert_nil actual
              end
            when 9
              reference.clear
              map.clear
            when 10
              assert_equal reference.key?(key), map.key?(key)
              assert_equal reference.to_h, map.each.to_h
            end

            assert_equal reference.max_size, map.max_size
            assert_equal reference.size, map.size
            assert_equal reference.to_h, map.to_h
          end

          assert_equal reference.shift, map.shift until reference.empty?

          assert_nil map.shift
        end
      end

      private

      def assert_identical(expected, actual)
        assert expected.equal?(actual), "expected #{expected.inspect}, got #{actual.inspect}" # rubocop:disable Minitest/AssertSame
      end
    end
  end
end
