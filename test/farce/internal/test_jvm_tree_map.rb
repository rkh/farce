# frozen_string_literal: true

jvm = RUBY_ENGINE == "jruby" || (RUBY_ENGINE == "truffleruby" && !TruffleRuby.native?)
return unless jvm

require_relative "../../setup"

module Farce
  module Internal
    class JVMTreeRank
      include Comparable

      attr_reader :rank

      def initialize(rank, error: nil, reenter: nil, freeze_target: nil)
        @rank = rank
        @error = error
        @reenter = reenter
        @freeze_target = freeze_target
      end

      def <=>(other)
        raise @error if @error
        @reenter&.clear
        @freeze_target&.freeze
        rank <=> other.rank
      end
    end

    class JVMFractionalTreeRank
      attr_reader :rank

      def initialize(rank) = @rank = rank

      def <=>(other) = (rank <=> other.rank) / 2.0
    end

    class JVMFirstTreeComparisonBomb
      def <=>(_other) = raise "first key must not be compared with itself"
    end

    class JVMHostileTreeString < String
      attr_reader :snapshot_marker

      def initialize(value)
        super
        @snapshot_marker = Object.new
      end

      def dup = self
      def freeze = self
    end

    class JVMCoercingTreeRank < Numeric
      attr_reader :rank

      def initialize(rank, freeze_target)
        super()
        @rank = rank
        @freeze_target = freeze_target
      end

      def <=>(other) = rank <=> (other.respond_to?(:rank) ? other.rank : other)

      def coerce(other)
        @freeze_target.freeze
        [other, rank]
      end
    end

    class JVMBlockingTreeRank
      attr_reader :rank

      def initialize(rank, entered: nil, release: nil)
        @rank = rank
        @entered = entered
        @release = release
      end

      def <=>(other)
        if @entered
          @entered << true
          @release.pop
          @entered = @release = nil
        end
        rank <=> other.rank
      end
    end

    class JVMGuardProbeLock
      attr_reader :entered, :release

      def initialize
        @entered = Thread::Queue.new
        @release = Thread::Queue.new
        @held = true
        @unlocked = false
      end

      def tryLock = true # rubocop:disable Naming/MethodName, Naming/PredicateMethod

      def isHeldByCurrentThread # rubocop:disable Naming/MethodName
        entered << true
        release.pop
        @held
      end

      def unlock
        @held = false
        @unlocked = true
      end

      def unlocked? = @unlocked
    end

    JVM_TREE_MUTATION_OWNER_PROBE = :farce_jvm_tree_mutation_owner_probe

    module JVMMutationOwnerTeardownProbe
      def mutation_owner=(value)
        probe = Thread.current.thread_variable_get(JVM_TREE_MUTATION_OWNER_PROBE)
        if value.nil? && probe
          probe.fetch(0) << true
          probe.fetch(1).pop
        end
        super
      end
    end

    class TestJVMTreeMaps < Test
      MAPS = [Internal::LocalTreeMap, Internal::TreeMap].freeze

      MAPS.each do |map_class|
        label = map_class.name.split("::").last

        define_method("test_#{label}_complete_map_contract") do
          object = Object.new
          map = map_class.new(10 => :ten, 2 => nil, 7 => object)

          assert_equal 3, map.size
          assert_equal map.size, map.length
          assert_equal 2, map.first_key
          assert_nil map[2]
          assert_same object, map[7]
          assert_nil map[8]

          assert_equal :replacement, map[10] = :replacement
          assert_equal 3, map.size
          assert_nil map.delete(2)
          assert_equal 2, map.size
          assert_equal [7, object], map.shift
          assert_equal [10, :replacement], map.shift
          assert_nil map.shift
          assert_predicate map, :empty?

          assert_same map, map.clear
          assert_raises(TypeError) { map.dup }
          assert_raises(TypeError) { map_class.new([]) }
          fake_hash = Object.new
          fake_hash.define_singleton_method(:is_a?) { |_class| true }
          fake_hash.define_singleton_method(:each) { raise "fake hash must not be iterated" }
          assert_raises(TypeError) { map_class.new(fake_hash) }
        end

        define_method("test_#{label}_initialization_is_transactional_and_one_shot") do
          map = map_class.allocate
          source = Object.new
          source.define_singleton_method(:to_hash) do
            map.send(:initialize, 1 => :inner)
            { 2 => :outer }
          end

          error = assert_raises(RuntimeError) { map.send(:initialize, source) }
          assert_match(/already initialized/, error.message)
          assert_equal 1, map.size
          assert_equal :inner, map[1]
          assert_nil map[2]
          assert_raises(RuntimeError) { map.send(:initialize, 3 => :third) }

          frozen_map = map_class.allocate
          frozen_map.freeze
          assert_raises(FrozenError) { frozen_map.send(:initialize) }
          assert_raises(RuntimeError) { frozen_map.size }
        end

        define_method("test_#{label}_failed_initial_entries_do_not_publish_partial_state") do
          map = map_class.allocate
          first = JVMTreeRank.new(1)
          exploding = JVMTreeRank.new(2, error: "initial comparison exploded")

          error = assert_raises(RuntimeError) do
            map.send(:initialize, first => :first, exploding => :exploding)
          end
          assert_equal "initial comparison exploded", error.message
          assert_raises(RuntimeError) { map.size }

          map.send(:initialize, 3 => :recovered)

          assert_equal 1, map.size
          assert_equal :recovered, map[3]
        end

        define_method("test_#{label}_initial_entries_remain_private_until_complete") do
          map = map_class.allocate
          entered = Thread::Queue.new
          release = Thread::Queue.new
          first = JVMBlockingTreeRank.new(1)
          second = JVMBlockingTreeRank.new(2, entered:, release:)
          initializer = Thread.new do
            map.send(:initialize, first => :first, second => :second)
          end

          entered.pop
          error = assert_raises(RuntimeError) { map.size }
          assert_match(/not initialized/, error.message)
          release << true

          assert initializer.join(2), "initializer did not finish"
          initializer.value

          assert_equal 2, map.size
          assert_equal :first, map[first]
          assert_equal :second, map[second]
        ensure
          release << true if release
          initializer&.kill if initializer&.alive?
        end

        define_method("test_#{label}_comparison_equivalence_and_exception_recovery") do
          first = JVMTreeRank.new(1)
          equivalent = JVMTreeRank.new(1)
          map = map_class.new
          map[first] = :first
          map[equivalent] = :replacement

          assert_equal 1, map.size
          assert_equal :replacement, map[first]
          assert_same first, map.first_key

          exploding = JVMTreeRank.new(2, error: "comparison exploded")
          error = assert_raises(RuntimeError) { map[exploding] = :bad }
          assert_equal "comparison exploded", error.message
          assert_equal 1, map.size
          assert_equal :replacement, map[first]
          assert_equal :three, map[JVMTreeRank.new(3)] = :three
        end

        define_method("test_#{label}_first_key_does_not_require_self_comparison") do
          key = JVMFirstTreeComparisonBomb.new
          map = map_class.new(key => :value)

          assert_equal 1, map.size
          assert_same key, map.first_key
        end

        define_method("test_#{label}_preserves_the_sign_of_fractional_comparisons") do
          map = map_class.new
          map[JVMFractionalTreeRank.new(2)] = :second
          map[JVMFractionalTreeRank.new(1)] = :first

          assert_equal 1, map.first_key.rank
          assert_equal :first, map.shift.last
          assert_equal :second, map.shift.last
        end
      end

      def test_local_tree_map_honors_freeze_and_reentrant_mutation_guard
        map = Internal::LocalTreeMap.new(1 => :one)
        recursive = JVMTreeRank.new(2, reenter: map)
        error = assert_raises(RuntimeError) { map[recursive] = :two }
        assert_match(/cannot be modified during comparison/, error.message)

        map.freeze
        assert_raises(FrozenError) { map[2] = :two }
        assert_raises(FrozenError) { map.delete(1) }
        assert_raises(FrozenError) { map.shift }
        assert_raises(FrozenError) { map.pop }
        assert_raises(FrozenError) { map.clear }
        assert_equal :one, map[1]
      end

      def test_local_tree_map_freeze_cannot_be_hidden_by_an_override
        map_class = Class.new(Internal::LocalTreeMap) do
          def frozen? = false
        end
        map = map_class.new(1 => :one)
        map.freeze

        assert Object.instance_method(:frozen?).bind_call(map)
        assert_raises(FrozenError) { map[2] = :two }
        assert_raises(FrozenError) { map.delete(1) }
        assert_raises(FrozenError) { map.shift }
        assert_raises(FrozenError) { map.pop }
        assert_raises(FrozenError) { map.clear }
        assert_equal :one, map[1]
      end

      def test_local_tree_map_callback_freeze_prevents_the_pending_mutation
        map = Internal::LocalTreeMap.new
        one = JVMTreeRank.new(1)
        map[one] = :one
        freezing = JVMTreeRank.new(2, freeze_target: map)

        assert_raises(FrozenError) { map[freezing] = :two }
        assert_predicate map, :frozen?
        assert_equal 1, map.size
        assert_equal :one, map[one]
      end

      def test_local_tree_map_detects_freeze_from_stored_numeric_coercion
        map = Internal::LocalTreeMap.new
        stored = JVMCoercingTreeRank.new(2, map)
        map[stored] = :stored

        assert_raises(FrozenError) { map[1] = :new }
        assert_predicate map, :frozen?
        assert_equal 1, map.size
        assert_equal :stored, map[stored]
      end

      def test_local_tree_map_uses_a_primitive_frozen_string_snapshot
        map = Internal::LocalTreeMap.new
        original = JVMHostileTreeString.new("middle")
        map[original] = :middle
        stored = map.first_key

        original.replace("zzzz")
        map[JVMHostileTreeString.new("alpha")] = :alpha
        map[JVMHostileTreeString.new("omega")] = :omega

        refute_same original, stored
        assert_instance_of JVMHostileTreeString, stored
        assert_same original.snapshot_marker, stored.snapshot_marker
        assert_predicate stored, :frozen?
        assert_equal %i[alpha middle omega], [map.shift.last, map.shift.last, map.shift.last]
      end

      def test_shared_tree_map_is_frozen_but_guarded_methods_mutate
        map = Internal::TreeMap.new

        assert_predicate map, :frozen?
        assert_equal :one, map[1] = :one
        assert_equal :one, map.delete(1)

        map[1] = :one
        recursive = JVMTreeRank.new(2, reenter: map)
        assert_raises(ThreadError) { map[recursive] = :two }
        assert_equal :one, map[1]
      end

      def test_shared_tree_map_initialization_uses_primitive_freeze
        map_class = Class.new(Internal::TreeMap) do
          def freeze = raise "overrideable freeze must not run"
        end

        map = map_class.new

        assert_predicate map, :frozen?
        assert_equal :one, map[1] = :one
      end

      def test_guard_teardown_cannot_be_interrupted_before_unlock
        guard = Internal::JVMOperationGuard.new(synchronized: true, label: "probe")
        lock = JVMGuardProbeLock.new
        guard.instance_variable_set(:@lock, lock)
        cancellation = Class.new(StandardError)
        worker = Thread.new do
          guard.synchronize { :done }
        rescue StandardError => e
          e
        end

        lock.entered.pop
        worker.raise(cancellation, "cancel teardown")
        lock.release << true

        assert worker.join(2), "cancelled guard did not finish"
        assert_instance_of cancellation, worker.value
        assert_predicate lock, :unlocked?
      ensure
        lock&.release&.push(true)
        worker&.kill if worker&.alive?
      end

      def test_local_mutation_owner_teardown_cannot_be_interrupted_before_clear
        backend = Internal.const_get(:JVMTreeMapBackend, false)
        key_class = backend.const_get(:Key, false)
        key_class.prepend(JVMMutationOwnerTeardownProbe) unless
          key_class < JVMMutationOwnerTeardownProbe
        map = Internal::LocalTreeMap.new(1 => :one)
        entered = Thread::Queue.new
        release = Thread::Queue.new
        cancellation = Class.new(StandardError)
        worker = Thread.new do
          Thread.current.thread_variable_set(JVM_TREE_MUTATION_OWNER_PROBE, [entered, release])
          map[2] = :two
        rescue StandardError => e
          e
        ensure
          Thread.current.thread_variable_set(JVM_TREE_MUTATION_OWNER_PROBE, nil)
        end

        entered.pop
        worker.raise(cancellation, "cancel mutation-owner teardown")
        release << true

        assert worker.join(2), "cancelled mutation-owner teardown did not finish"
        assert_instance_of cancellation, worker.value

        map.freeze

        assert_equal :one, map[1]
        assert_equal :two, map[2]
      ensure
        release&.push(true)
        worker&.kill if worker&.alive?
      end

      def test_shared_tree_map_parallel_writers_and_deleters
        map = Internal::TreeMap.new
        writers = 8.times.map do |worker|
          Thread.new do
            400.times do |index|
              key = (worker * 10_000) + index
              map[key] = key
            end
          end
        end
        writers.each(&:value)

        assert_equal 3_200, map.size

        deleters = 8.times.map do |worker|
          Thread.new do
            200.times do |index|
              key = (worker * 10_000) + index
              raise "lost #{key}" unless map.delete(key) == key
            end
          end
        end
        deleters.each(&:value)

        assert_equal 1_600, map.size
        assert_equal 200, map.first_key
      end

      def test_initialization_accepts_to_hash
        entries = Object.new
        entries.define_singleton_method(:to_hash) { { 2 => :two, 1 => :one } }

        map = Internal::TreeMap.new(entries)

        assert_equal [1, :one], map.shift
        assert_equal [2, :two], map.shift
      end
    end

    class TestJVMTreeMapPublicClasses < Test
      def test_default_is_synchronized_and_local_variant_is_explicit
        map = Internal::TreeMap.new(2 => :two, 1 => :one)
        local = Internal::LocalTreeMap.new(2 => :two, 1 => :one)

        assert_same Internal::TreeMap, Internal::ShareableTreeMap
        assert_instance_of Internal::TreeMap, map
        assert_instance_of Internal::LocalTreeMap, local
        assert_equal Object, Internal::TreeMap.superclass
        assert_equal Object, Internal::LocalTreeMap.superclass
        assert_predicate map, :frozen?
        refute_predicate local, :frozen?
        assert_equal [1, :one], map.shift
        assert_equal [1, :one], local.shift
      end

      def test_default_map_is_safe_for_parallel_use
        map = Internal::TreeMap.new
        threads = 4.times.map do |worker|
          Thread.new do
            250.times do |index|
              key = (worker * 1_000) + index
              map[key] = key
            end
          end
        end
        threads.each(&:value)

        assert_equal 1_000, map.size
        assert_equal 0, map.first_key
        assert_equal 3_249, map[3_249]
      end
    end
  end
end
