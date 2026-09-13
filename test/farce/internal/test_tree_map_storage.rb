# frozen_string_literal: true

supported = RUBY_ENGINE == "ruby" ||
  (RUBY_ENGINE == "truffleruby" && TruffleRuby.native?)
return unless supported

require_relative "../../setup"

module Farce
  module Internal
    class TreeMapRankedKey
      include Comparable

      attr_reader :rank

      def initialize(
        rank,
        error: nil,
        reenter: nil,
        reenter_thread_target: false,
        freeze_target: nil,
        freeze_thread_target: false,
        yield_thread: false,
        yield_fiber: false,
        resume_contender: false
      )
        @rank = rank
        @error = error
        @reenter = reenter
        @reenter_thread_target = reenter_thread_target
        @freeze_target = freeze_target
        @freeze_thread_target = freeze_thread_target
        @yield_thread = yield_thread
        @yield_fiber = yield_fiber
        @resume_contender = resume_contender
        freeze
      end

      def <=>(other)
        raise @error if @error
        @reenter&.clear
        Thread.current[:tree_map_reentry_target]&.clear if @reenter_thread_target
        @freeze_target&.freeze
        Thread.current[:tree_map_freeze_target]&.freeze if @freeze_thread_target
        Thread.pass if @yield_thread
        Fiber.scheduler&.kernel_sleep(0.01) if @yield_fiber
        Thread.current[:tree_map_contender]&.resume if @resume_contender
        rank <=> other.rank
      end
    end

    class FirstTreeComparisonBomb
      def initialize = freeze
      def <=>(_other) = raise "first key must not be compared with itself"
    end

    class TreeMapFiberReentryKey
      attr_reader :rank

      def initialize(rank, resume_at:)
        @rank = rank
        @resume_at = resume_at
        freeze
      end

      def <=>(other)
        counts = Thread.current[:tree_map_fiber_reentry_counts] ||= Hash.new(0)
        counts[self] += 1
        Thread.current[:unsafe_tree_map_contender]&.resume if counts[self] == @resume_at
        rank <=> other.rank
      end
    end

    class HostileTreeMapStringKey < String
      attr_reader :snapshot_marker

      def initialize(value)
        super
        @snapshot_marker = Object.new
      end

      def dup = self
      def freeze = self
    end

    class TreeMapWaitCancellation < StandardError; end

    class TreeMapPublicationReentry
      attr_reader :reentry_rejected

      def initialize(target)
        @target = target
        @reentry_rejected = false
      end

      def freeze
        begin
          @target.send(:initialize)
        rescue FrozenError, ThreadError
          @reentry_rejected = true
        end
        super
      end
    end

    class CancellingTreeMapScheduler < Helpers::QueueTestScheduler
      def cancel_next_io_wait!
        @cancel_next_io_wait = true
      end

      def io_wait(...)
        result = super
        if @cancel_next_io_wait
          @cancel_next_io_wait = false
          raise TreeMapWaitCancellation, "cancel notified waiter"
        end
        result
      end

      def run_once = send(:run)

      def waiting_io_ready?
        descriptors = instance_variable_get(:@readable).keys
        !!IO.select(descriptors, nil, nil, 0)&.first&.any?
      end
    end

    module TreeMapStorageBehavior
      def test_basic_operations_and_initial_hash
        map = self.class::TreeMap.new(10 => "ten", 2 => "two", 7 => "seven")

        assert_equal 3, map.size
        assert_equal map.size, map.length
        assert_equal 2, map.first_key
        assert_equal 10, map.last_key
        assert_equal "seven", map[7]
        assert_nil map[8]

        assert_equal "TEN", map[10] = "TEN"
        assert_equal 3, map.size
        assert_equal "two", map.delete(2)
        assert_nil map.delete(2)
        assert_equal [10, "TEN"], map.pop
        assert_equal [7, "seven"], map.shift
        assert_nil map.pop
        assert_nil map.shift
        assert_empty map
      end

      def test_comparison_equivalence_replaces_the_original_value
        first = TreeMapRankedKey.new(1)
        equivalent = TreeMapRankedKey.new(1)
        map = self.class::TreeMap.new

        map[first] = :first
        map[equivalent] = :replacement

        assert_equal 1, map.size
        assert_equal :replacement, map[first]
        assert_same first, map.first_key
      end

      def test_first_key_does_not_require_self_comparison
        key = FirstTreeComparisonBomb.new
        map = self.class::TreeMap.new(key => :value)

        assert_equal 1, map.size
        assert_same key, map.first_key
      end

      def test_float_ordering_infinities_and_nan_match_spaceship
        map = self.class::TreeMap.new
        map[Float::INFINITY] = :positive_infinity
        map[1.5] = :middle
        map[-Float::INFINITY] = :negative_infinity

        assert_equal [
          [-Float::INFINITY, :negative_infinity],
          [1.5, :middle],
          [Float::INFINITY, :positive_infinity]
        ], [map.shift, map.shift, map.shift]

        map[0.0] = :zero
        assert_raises(ArgumentError) { map[Float::NAN] = :nan }
        assert_equal [[0.0, :zero]], [map.shift]
      end

      def test_small_and_large_integer_keys_share_one_order
        huge = 1 << 100
        map = self.class::TreeMap.new(
          huge  => :huge,
          -7    => :small_negative,
          -huge => :negative_huge,
          3     => :small_positive,
        )

        assert_equal(
          %i[negative_huge small_negative small_positive huge],
          4.times.map { map.shift.last },
        )
      end

      def test_clear
        map = self.class::TreeMap.new(1 => :one, 2 => :two)

        assert_same map, map.clear
        assert_empty map
        assert_nil map.first_key
        assert_same map, map.clear
        assert_equal :three, map[3] = :three
      end

      def test_comparison_exception_leaves_tree_intact
        one = TreeMapRankedKey.new(1)
        map = self.class::TreeMap.new(one => :one)
        exploding = TreeMapRankedKey.new(2, error: "comparison failed")

        error = assert_raises(RuntimeError) { map[exploding] = :two }
        assert_equal "comparison failed", error.message
        assert_equal 1, map.size
        assert_equal :one, map[one]
        assert_same one, map.first_key

        map[TreeMapRankedKey.new(3)] = :three

        assert_equal 2, map.size
      end

      def test_gc_compaction_updates_keys_and_values
        map = self.class::TreeMap.new
        expected = {}

        1_500.times do |index|
          key = "key-%04d" % index
          value = "value-%04d" % index
          key.freeze
          value.freeze
          expected[key] = value
          map[key] = value
        end

        GC.start
        GC.compact if GC.respond_to?(:compact)

        assert_equal expected.size, map.size
        expected.each { |key, value| assert_equal value, map[key] }
      end

      def test_randomized_differential
        16.times do |seed|
          random = Random.new(seed)
          map = self.class::TreeMap.new
          model = {}

          1_200.times do |step|
            key = random.rand(-50..50)
            case random.rand(6)
            when 0, 1
              value = (seed * 10_000) + step
              model[key] = value

              assert_equal value, map[key] = value
            when 2
              expected = model.delete(key)
              actual = map.delete(key)

              assert_optional_equal(expected, actual, "seed #{seed}, step #{step}")
            when 3
              expected = model[key]
              actual = map[key]

              assert_optional_equal(expected, actual, "seed #{seed}, step #{step}")
            when 4
              if model.empty?
                expected = nil
              else
                first = model.keys.min
                expected = [first, model.delete(first)]
              end
              actual = map.shift

              assert_optional_equal(expected, actual, "seed #{seed}, step #{step}")
            when 5
              if model.empty?
                expected = nil
              else
                last = model.keys.max
                expected = [last, model.delete(last)]
              end
              actual = map.pop

              assert_optional_equal(expected, actual, "seed #{seed}, step #{step}")
            end

            assert_equal model.size, map.size, "seed #{seed}, step #{step}"
            assert_equal model.empty?, map.empty?, "seed #{seed}, step #{step}"
            expected_first = model.keys.min
            actual_first = map.first_key
            expected_last = model.keys.max
            actual_last = map.last_key

            assert_optional_equal(expected_first, actual_first, "seed #{seed}, step #{step}")
            assert_optional_equal(expected_last, actual_last, "seed #{seed}, step #{step}")
          end

          actual = []
          actual << map.shift until map.empty?

          assert_equal model.sort, actual, "seed #{seed} drain"
        end
      end

      def test_copy_is_explicitly_unsupported
        map = self.class::TreeMap.new(1 => :one)
        assert_raises(TypeError) { map.dup }
        assert_equal :one, map[1]
      end

      def test_initialization_requires_a_hash_like_object
        assert_raises(TypeError) { self.class::TreeMap.new([]) }
      end

      def test_initialize_honors_freeze_before_and_after_hash_conversion
        map = self.class::TreeMap.allocate
        map.freeze

        assert_raises(FrozenError) { map.send(:initialize) }
        assert_raises(RuntimeError) { map.size }

        map = self.class::TreeMap.allocate
        source = Object.new
        source.define_singleton_method(:to_hash) do
          map.freeze
          { 1 => :one }
        end

        assert_raises(FrozenError) { map.send(:initialize, source) }
        assert_raises(RuntimeError) { map.size }
      end

      def test_comparator_freeze_aborts_initialization
        map = self.class::TreeMap.allocate
        first = TreeMapRankedKey.new(1)
        freezing = TreeMapRankedKey.new(2, freeze_thread_target: true)
        Thread.current[:tree_map_freeze_target] = map

        assert_raises(FrozenError) do
          map.send(:initialize, first => :first, freezing => :second)
        end
        assert_predicate map, :frozen?
        assert_raises(RuntimeError) { map.size }
      ensure
        Thread.current[:tree_map_freeze_target] = nil
      end

      private

      def assert_optional_equal(expected, actual, message)
        expected.nil? ? assert_nil(actual, message) : assert_equal(expected, actual, message)
      end
    end

    class TestUnsafeTreeMapStorage < Test
      include TreeMapStorageBehavior

      TreeMap = Internal::UnsafeTreeMap

      def test_local_map_is_unshareable_and_honors_freeze
        map = TreeMap.new(1 => :one)
        refute Ractor.shareable?(map) if RUBY_ENGINE == "ruby"

        map.freeze
        assert_raises(FrozenError) { map[2] = :two }
        assert_raises(FrozenError) { map.delete(1) }
        assert_raises(FrozenError) { map.shift }
        assert_raises(FrozenError) { map.pop }
        assert_raises(FrozenError) { map.clear }
      end

      def test_hash_conversion_cannot_reinitialize_the_map
        map = TreeMap.allocate
        source = Object.new
        source.define_singleton_method(:to_hash) do
          map.send(:initialize, 1 => :one)
          { 2 => :two }
        end

        error = assert_raises(RuntimeError) { map.send(:initialize, source) }
        assert_match(/already initialized/, error.message)
        assert_equal 1, map.size
        assert_equal :one, map[1]
        assert_nil map[2]
      end

      def test_comparison_cannot_reenter_a_mutation
        map = TreeMap.new
        one = TreeMapRankedKey.new(1)
        map[one] = :one
        Thread.current[:tree_map_reentry_target] = map

        error = assert_raises(RuntimeError) do
          map[TreeMapRankedKey.new(2, reenter_thread_target: true)] = :two
        end
        assert_match(/modified during comparison|cannot be modified during comparison/, error.message)
        assert_equal 1, map.size
        assert_equal :one, map[one]
      ensure
        Thread.current[:tree_map_reentry_target] = nil
      end

      def test_comparison_cannot_reenter_from_another_fiber_on_the_same_thread
        one = TreeMapFiberReentryKey.new(1, resume_at: 99)
        map = TreeMap.new(one => :one)
        Thread.current[:unsafe_tree_map_contender] = Fiber.new { map.clear }
        two = TreeMapFiberReentryKey.new(2, resume_at: 1)

        error = assert_raises(RuntimeError) { map[two] = :two }

        assert_match(/modified during comparison|cannot be modified during comparison/, error.message)
        assert_equal 1, map.size
        assert_equal :one, map[one]
        assert_nil map[two]
      ensure
        Thread.current[:unsafe_tree_map_contender] = nil
        Thread.current[:tree_map_fiber_reentry_counts] = nil
      end

      def test_comparator_freeze_prevents_a_pending_mutation
        map = TreeMap.new
        one = TreeMapRankedKey.new(1)
        map[one] = :one
        Thread.current[:tree_map_freeze_target] = map

        error = assert_raises(FrozenError) do
          map[TreeMapRankedKey.new(2, freeze_thread_target: true)] = :two
        end
        assert_match(/frozen/i, error.message)
        assert_equal 1, map.size
        assert_equal :one, map[one]

        map = TreeMap.new
        one = TreeMapRankedKey.new(1)
        map[one] = :one
        Thread.current[:tree_map_freeze_target] = map

        assert_raises(FrozenError) do
          map.delete(TreeMapRankedKey.new(1, freeze_thread_target: true))
        end
        assert_equal 1, map.size
        assert_equal :one, map[one]
      ensure
        Thread.current[:tree_map_freeze_target] = nil
      end

      def test_mutating_an_inserted_string_does_not_corrupt_ordering
        original = +"middle"
        map = TreeMap.new

        map[original] = :middle
        stored = map.first_key

        original.replace("zzzz")
        GC.start
        GC.compact if GC.respond_to?(:compact)
        map["alpha"] = :alpha
        map["omega"] = :omega

        refute_same original, stored
        assert_same(-"middle", stored)
        assert_same stored, map.getkey(+"middle")
        assert_predicate stored, :frozen?
        assert_equal :middle, map["middle"]
        assert_nil map["zzzz"]
        assert_equal [["alpha", :alpha], ["middle", :middle], ["omega", :omega]],
          [map.shift, map.shift, map.shift]
      end

      def test_primitive_string_snapshot_bypasses_dup_and_freeze_overrides
        original = HostileTreeMapStringKey.new("middle")
        map = TreeMap.new

        if RUBY_ENGINE == "ruby"
          assert_raises(Ractor::IsolationError) { map[original] = :middle }
          return
        end

        map[original] = :middle
        stored = map.first_key

        original.replace("zzzz")
        map[HostileTreeMapStringKey.new("alpha")] = :alpha
        map[HostileTreeMapStringKey.new("omega")] = :omega

        refute_same original, stored
        assert_instance_of HostileTreeMapStringKey, stored
        assert_same original.snapshot_marker, stored.snapshot_marker
        assert_predicate stored, :frozen?
        assert_equal %i[alpha middle omega], [map.shift.last, map.shift.last, map.shift.last]
      end
    end

    class TestTreeMapStorage < Test
      include TreeMapStorageBehavior

      TreeMap = Internal::TreeMap

      def test_synchronized_map_is_unshareable_and_accepts_arbitrary_values
        value = Object.new
        map = TreeMap.new(1 => value)

        refute Ractor.shareable?(map) if RUBY_ENGINE == "ruby"

        assert_same value, map[1]
      end

      def test_synchronized_map_honors_freeze
        return unless RUBY_ENGINE == "ruby"

        map = TreeMap.new(1 => :one)
        map.freeze

        assert_raises(FrozenError) { map[2] = :two }
        assert_raises(FrozenError) { map.delete(1) }
        assert_raises(FrozenError) { map.shift }
        assert_raises(FrozenError) { map.pop }
        assert_raises(FrozenError) { map.clear }
      end

      def test_concurrent_thread_writers
        map = TreeMap.new
        writers = 4.times.map do |worker|
          Thread.new do
            250.times do |index|
              key = (worker * 1_000) + index
              map[key] = key
            end
          end
        end
        writers.each(&:value)

        assert_equal 1_000, map.size
        assert_equal 0, map.first_key
      end
    end

    class TestShareableTreeMapStorage < Test
      include Helpers::InternalTestHelpers

      include TreeMapStorageBehavior

      TreeMap = Internal::ShareableTreeMap

      def test_cruby_native_publication_is_atomic_at_first_ractor_visibility
        return unless RUBY_ENGINE == "ruby"

        assert_atomic_ractor_publication(TreeMap) do |map|
          map.send(:initialize)
        end
      end

      def test_tree_map_is_frozen_and_ractor_shareable_on_cruby
        map = TreeMap.new

        assert_predicate map, :frozen?
        assert Ractor.shareable?(map) if RUBY_ENGINE == "ruby"

        # Frozen is the object's shareability boundary, not a ban on its guarded
        # C methods mutating internal state.
        assert_equal :one, map[1] = :one
        assert_equal :one, map.delete(1)
      end

      def test_cruby_publication_recursively_shares_preinitialize_ivars
        return unless RUBY_ENGINE == "ruby"

        map = TreeMap.allocate
        metadata = Object.new
        metadata.instance_variable_set(:@values, [1, 2, 3])
        map.instance_variable_set(:@metadata, metadata)

        assert_same map, map.send(:initialize, 1.0 => :one)
        assert_predicate map, :frozen?
        assert_predicate metadata, :frozen?
        assert_predicate metadata.instance_variable_get(:@values), :frozen?
        assert Ractor.shareable?(map)
        assert Ractor.shareable?(metadata)

        worker = Ractor.new(map) do |shared_map|
          [
            shared_map[1.0],
            shared_map.instance_variable_get(:@metadata)
              .instance_variable_get(:@values)
          ]
        end
        result = worker.respond_to?(:value) ? worker.value : worker.take

        assert_equal [:one, [1, 2, 3]], result
      end

      def test_cruby_publication_does_not_commit_an_unshareable_ivar
        return unless RUBY_ENGINE == "ruby"

        map = TreeMap.allocate
        map.instance_variable_set(:@thread, Thread.current)

        assert_raises(Ractor::Error) { map.send(:initialize, 1 => :one) }
        refute Ractor.shareable?(map)
        assert_raises(RuntimeError) { map.size }
      end

      def test_cruby_recursive_initialize_from_ivar_freeze_does_not_deadlock
        return unless RUBY_ENGINE == "ruby"

        map = TreeMap.allocate
        metadata = TreeMapPublicationReentry.new(map)
        map.instance_variable_set(:@metadata, metadata)

        Timeout.timeout(2) { map.send(:initialize) }

        assert_predicate metadata, :reentry_rejected
        assert Ractor.shareable?(map)
      end

      def test_concurrent_initializers_commit_only_once
        # TruffleRuby serializes these nested C-to-Ruby #to_hash callbacks, so
        # the barrier itself cannot be reached by both native threads there.
        return unless RUBY_ENGINE == "ruby"

        map = TreeMap.allocate
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
            map.send(:initialize, source)
            :initialized
          rescue RuntimeError => e
            e
          end
        end
        2.times { arrived.pop }
        2.times { release << true }
        results = threads.map(&:value)

        assert_equal 1, results.count(:initialized)
        error = results.grep(RuntimeError).fetch(0)

        assert_match(/already initialized/, error.message)
        assert_equal 1, map.size
        assert_includes [0, 1], map.first_key
        assert_equal map.first_key, map[map.first_key]
      ensure
        2.times { release << true } if release
        threads&.each { it.kill if it.alive? }
      end

      def test_unshareable_inputs_are_rejected_on_cruby
        return unless RUBY_ENGINE == "ruby"

        map = TreeMap.new
        assert_raises(Ractor::IsolationError) { map[Object.new] }
        assert_raises(Ractor::IsolationError) { map[Object.new] = :value }
        assert_raises(Ractor::IsolationError) { map[:key] = Object.new }
        assert_raises(Ractor::IsolationError) { map.delete(Object.new) }
        assert_raises(Ractor::IsolationError) { TreeMap.new({ key: Object.new }) }
        assert_empty map
      end

      def test_recursive_comparison_access_raises_without_deadlock
        map = TreeMap.new
        one = TreeMapRankedKey.new(1)
        map[one] = :one
        recursive = TreeMapRankedKey.new(2, reenter: map)

        error = assert_raises(ThreadError) { map[recursive] = :two }
        assert_match(/recursive tree map access/, error.message)
        assert_equal 1, map.size
        assert_equal :one, map[one]
        assert_equal :three, map[TreeMapRankedKey.new(3)] = :three
      end

      def test_thread_contention_during_ruby_comparisons
        map = TreeMap.new
        threads = 6.times.map do |worker|
          Thread.new do
            250.times do |index|
              rank = (worker * 1_000) + index
              map[TreeMapRankedKey.new(rank, yield_thread: true)] = rank
            end
          end
        end

        threads.each do |thread|
          assert thread.join(10), "tree-map worker deadlocked"
          thread.value
        end

        assert_equal 1_500, map.size
        assert_equal 0, map.first_key.rank
      ensure
        threads&.each { |thread| thread.kill if thread.alive? }
      end

      def test_comparator_contention_parks_only_the_waiting_fiber_on_cruby
        return unless RUBY_ENGINE == "ruby" && Fiber.respond_to?(:set_scheduler)

        begin
          scheduler = Helpers::QueueTestScheduler.new
          Fiber.set_scheduler(scheduler)
          map = TreeMap.new(TreeMapRankedKey.new(1) => :one)
          events = []

          Fiber.schedule do
            events << :storing
            map[TreeMapRankedKey.new(2, yield_fiber: true)] = :two
            events << :stored
          end
          Fiber.schedule do
            events << :waiting
            events << map.size
          end
          Fiber.set_scheduler(nil)

          assert_equal %i[storing waiting stored] + [2], events
          assert_operator scheduler.io_wait_calls, :>=, 1
          assert_equal :two, map[TreeMapRankedKey.new(2)]
        ensure
          Fiber.set_scheduler(nil) if Fiber.respond_to?(:scheduler) && Fiber.scheduler
        end
      end

      def test_canceling_a_notified_lock_waiter_wakes_the_next_fiber
        return unless RUBY_ENGINE == "ruby"
        return unless Fiber.respond_to?(:set_scheduler)

        scheduler = CancellingTreeMapScheduler.new
        Fiber.set_scheduler(scheduler)
        map = TreeMap.new(TreeMapRankedKey.new(1) => :one)
        events = []
        scheduler.cancel_next_io_wait!

        Fiber.schedule do
          events << :owner_started
          map[TreeMapRankedKey.new(2, yield_fiber: true)] = :two
          events << :owner_finished
        end
        Fiber.schedule do
          events << :canceled_started
          map.size
        rescue TreeMapWaitCancellation
          events << :canceled
        end
        Fiber.schedule do
          events << :survivor_started
          events << map.size
        end

        4.times do
          break if events.include?(:canceled)

          Timeout.timeout(1) { scheduler.run_once }
        end

        assert_includes events, :canceled
        assert_predicate scheduler, :waiting_io_ready?, "the next tree-map lock waiter was stranded"

        scheduler.run_once

        assert_equal 2, events.last
        Fiber.set_scheduler(nil)
      ensure
        Fiber.set_scheduler(nil) if Fiber.respond_to?(:scheduler) && Fiber.scheduler
      end

      def test_unscheduled_same_thread_fiber_contention_raises_instead_of_deadlocking
        map = TreeMap.new(TreeMapRankedKey.new(1) => :one)
        Thread.current[:tree_map_contender] = Fiber.new { map.size }

        error = assert_raises(ThreadError) do
          map[TreeMapRankedKey.new(2, resume_contender: true)] = :two
        end
        assert_match(/recursive tree map access|another (?:unscheduled )?fiber/, error.message)
        assert_equal 1, map.size
        assert_equal :one, map[TreeMapRankedKey.new(1)]
      ensure
        Thread.current[:tree_map_contender] = nil
      end

      def test_concurrent_thread_writers_and_deleters
        map = TreeMap.new
        writers = 8.times.map do |worker|
          Thread.new do
            500.times do |index|
              key = (worker * 10_000) + index
              map[key] = key
            end
          end
        end
        writers.each(&:value)

        assert_equal 4_000, map.size

        deleters = 8.times.map do |worker|
          Thread.new do
            250.times do |index|
              key = (worker * 10_000) + index
              raise "lost key #{key}" unless map.delete(key) == key
            end
          end
        end
        deleters.each(&:value)

        assert_equal 2_000, map.size
        assert_equal 250, map.first_key
      end

      def test_concurrent_ractor_writers
        return unless RUBY_ENGINE == "ruby"

        map = TreeMap.new
        workers = 4.times.map do |worker|
          Ractor.new(map, worker) do |shared, prefix|
            300.times do |index|
              key = (prefix * 10_000) + index
              shared[key] = key
            end
          end
        end
        workers.each { |worker| ractor_value(worker) }

        assert_equal 1_200, map.size
        assert_equal 0, map.first_key
        4.times do |worker|
          300.times do |index|
            key = (worker * 10_000) + index

            assert_equal key, map[key]
          end
        end
      end
    end
  end
end
