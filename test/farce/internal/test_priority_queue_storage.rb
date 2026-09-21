# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

supported = RUBY_ENGINE == "ruby" ||
  (RUBY_ENGINE == "truffleruby" && TruffleRuby.native?)
return unless supported

require_relative "../../setup"

module Farce
  module Internal
    module PriorityQueueStorageBehavior
      def queue_class = self.class.const_get(:QueueClass, false)

      def native_unshared_storage?
        Internal.native_ractors? &&
          queue_class.equal?(Internal::UnsharedPriorityQueue) &&
          !queue_class.equal?(Internal::PriorityQueue)
      end

      def new_queue(...) = queue_class.new(...)

      def new_queue_with_signal(signal:, capacity: 1024)
        queue = queue_class.allocate
        initialize_native_storage(queue, capacity:, signal:)
      end

      def initialize_native_storage(
        queue,
        capacity: 1024,
        signal: Internal::Signal.new
      )
        queue.send(:initialize, capacity:, signal:)
      end

      def native_push(queue, priority, value) = queue.push(priority, value)

      def native_pop(queue, &) = queue.pop(&)

      def share(value) = value.freeze

      def test_default_and_explicit_capacity
        assert_nil new_queue.capacity
        assert_equal 1024, new_queue(capacity: 1024).capacity
        assert_raises(ArgumentError) { new_queue(capacity: 0) }
        assert_raises(ArgumentError) { new_queue(capacity: -1) }
      end

      def test_capacity_validation_bypasses_a_hostile_is_a_override
        capacity = Object.new
        capacity.define_singleton_method(:is_a?) { |_type| true }
        capacity.define_singleton_method(:to_int) { Object.new }

        assert_raises(TypeError) { new_queue(capacity:) }
      end

      def test_a_frozen_allocated_queue_cannot_be_initialized
        queue = queue_class.allocate
        Object.instance_method(:freeze).bind_call(queue)

        assert_raises(FrozenError) { queue.send(:initialize, capacity: nil) }
      end

      def test_initialization_callback_cannot_freeze_then_initialize_the_queue
        queue = queue_class.allocate
        capacity = Object.new
        capacity.define_singleton_method(:to_int) do
          Object.instance_method(:freeze).bind_call(queue)
          1
        end

        assert_raises(FrozenError) { queue.send(:initialize, capacity:) }
        assert_raises(RuntimeError) { queue.size }
      end

      def test_capacity_callback_cannot_overwrite_a_recursive_initialization
        queue = queue_class.allocate
        capacity = Object.new
        capacity.define_singleton_method(:to_int) do
          queue.send(:initialize, capacity: 3)
          5
        end

        error = assert_raises(RuntimeError) do
          queue.send(:initialize, capacity:)
        end

        assert_match(/already initialized/, error.message)
        assert_equal 3, queue.capacity
      end

      def test_minimum_priority_and_fifo_ties
        queue = new_queue

        assert native_push(queue, 2, :later)
        assert native_push(queue, 1, :first)
        assert native_push(queue, 1, :second)
        assert_equal :first, queue.peek
        assert_equal 1, queue.peek_priority
        assert_equal :first, native_pop(queue)
        assert_equal :second, native_pop(queue)
        assert_equal :later, native_pop(queue)
        assert_predicate queue, :empty?
      end

      def test_maximum_priority_endpoint_and_fifo_ties
        queue = new_queue

        assert native_push(queue, 1, :earliest)
        assert native_push(queue, 3, :first)
        assert native_push(queue, 3, :second)
        assert native_push(queue, 2, :middle)
        assert_equal :first, queue.peek_last
        assert_equal 3, queue.peek_last_priority
        assert_equal :first, queue.pop_last
        assert_equal :second, queue.pop_last
        assert_equal :middle, queue.pop_last
        assert_equal :earliest, queue.pop_last
        assert_predicate queue, :empty?
        assert_equal(:empty, queue.pop_last { :empty })
        assert_equal(:empty, queue.peek_last { :empty })
        assert_equal(:empty, queue.peek_last_priority { :empty })
      end

      def test_first_priority_does_not_require_self_comparison
        priority = share(FirstComparisonBomb.new)
        queue = new_queue

        assert native_push(queue, priority, :value)
        assert_equal 1, queue.size
        assert_same priority, queue.peek_priority
        assert_equal :value, native_pop(queue)
      end

      def test_string_subclass_uses_its_overridden_comparator
        queue = new_queue
        first = share(ReverseStringPriority.new("a"))
        second = share(ReverseStringPriority.new("b"))

        native_push(queue, first, :a)
        native_push(queue, second, :b)

        assert_equal :b, native_pop(queue)
        assert_equal :a, native_pop(queue)
      end

      def test_float_ordering_and_nan_comparison_semantics
        queue = new_queue(capacity: nil)
        native_push(queue, 2.5, :later)
        native_push(queue, -Float::INFINITY, :first)
        native_push(queue, 2.5, :tie)

        assert_equal :first, native_pop(queue)
        assert_equal :later, native_pop(queue)
        assert_equal :tie, native_pop(queue)

        nan = Float::NAN

        assert native_push(queue, nan, :nan)
        assert_raises(ArgumentError) { native_push(queue, 1.0, :incomparable) }
        assert_equal 1, queue.size
        assert_predicate queue.peek_priority, :nan?
      end

      def test_small_and_large_integer_priorities_share_one_order
        queue = new_queue(capacity: nil)
        huge = 1 << 100
        native_push(queue, huge, :huge)
        native_push(queue, -7, :small_negative)
        native_push(queue, -huge, :negative_huge)
        native_push(queue, 3, :small_positive)

        assert_equal %i[negative_huge small_negative small_positive huge],
          [native_pop(queue), native_pop(queue), native_pop(queue), native_pop(queue)]
      end

      def test_capacity_is_nonblocking
        queue = new_queue(capacity: 2)

        assert native_push(queue, 1, :first)
        assert native_push(queue, 2, :second)
        refute native_push(queue, 0, :full)
        assert_equal 2, queue.size
        assert queue.delete(2, :second)
        assert native_push(queue, 0, :replacement)
        assert_equal :replacement, native_pop(queue)
      end

      def test_delete_removes_only_the_oldest_equal_value_at_the_exact_priority
        queue = new_queue

        native_push(queue, 1, :same)
        native_push(queue, 1, :other)
        native_push(queue, 1, :same)
        native_push(queue, 2, :same)

        assert queue.delete(1, :same)
        assert_equal :other, native_pop(queue)
        assert_equal :same, native_pop(queue)
        assert_equal :same, native_pop(queue)
        refute queue.delete(1, :same)
      end

      def test_delete_and_delete_identity_have_distinct_equality_contracts
        older = share(+"same")
        requested = share(+"same")

        refute_same older, requested

        equality_queue = new_queue
        native_push(equality_queue, 1, older)
        native_push(equality_queue, 1, requested)

        assert equality_queue.delete(1, requested)
        assert_same requested, native_pop(equality_queue)

        identity_queue = new_queue
        native_push(identity_queue, 1, older)
        native_push(identity_queue, 1, requested)

        assert identity_queue.delete_identity(1, requested)
        assert_same older, native_pop(identity_queue)
      end

      def test_delete_identity_removes_the_oldest_occurrence_of_the_same_object
        requested = share(+"same")
        equal_but_distinct = share(+"same")
        queue = new_queue
        native_push(queue, 1, requested)
        native_push(queue, 1, equal_but_distinct)
        native_push(queue, 1, requested)

        assert queue.delete_identity(1, requested)
        assert_same equal_but_distinct, native_pop(queue)
        assert_same requested, native_pop(queue)
        refute queue.delete_identity(1, requested)
      end

      def test_indexed_delete_identity_tracks_repeated_instances
        requested = share(+"requested")
        entries = 31.times.map { |index| share("filler-#{index}") }
        entries.insert(5, requested)
        entries.insert(25, requested)
        queue = new_queue(capacity: nil)
        entries.each { |value| native_push(queue, 1, value) }

        assert queue.delete_identity(1, requested)
        entries.delete_at(5)

        entries.each { |value| assert_same value, native_pop(queue) }
      end

      def test_lazy_identity_index_survives_all_mutations_and_compaction
        queue = new_queue(capacity: nil)
        expected = 64.times.map { |index| share(+format("value-%03d", index)) }
        expected.each { |value| native_push(queue, 1, value) }

        removed = expected.delete_at(40)

        assert queue.delete_identity(1, removed), "first indexed identity deletion"
        assert_same expected.shift, native_pop(queue)

        removed = expected.delete_at(10)
        equal_probe = share(+removed)

        assert queue.delete(1, equal_probe), "equality deletion updates the identity index"

        appended = share(+"appended")
        native_push(queue, 1, appended)
        expected << appended

        assert queue.delete_identity(1, appended), "push updates an existing identity index"
        expected.delete(appended)

        additions = 10.times.map { |index| share("addition-#{index}") }
        additions.each { |value| native_push(queue, 1, value) }
        expected.concat(additions)
        removed = additions.fetch(7)

        assert queue.delete_identity(1, removed), "identity index remains valid after resizing"
        expected.delete(removed)

        if GC.respond_to?(:compact)
          if GC.respond_to?(:verify_compaction_references)
            GC.verify_compaction_references(double_heap: true, toward: :empty)
          else
            GC.compact
          end
        end

        removed = expected.delete_at(20)

        assert queue.delete_identity(1, removed), "identity index is rebuilt after compaction"
        expected.each { |value| assert_same value, native_pop(queue) }
        assert_predicate queue, :empty?
      end

      def test_empty_fallbacks_run_outside_native_storage
        queue = new_queue

        assert_nil native_pop(queue)
        assert_nil queue.peek
        assert_nil queue.peek_priority
        assert_equal(:pop, native_pop(queue) { :pop })
        assert_equal(:peek, queue.peek { :peek })
        assert_equal(:priority, queue.peek_priority { :priority })
      end

      def test_clear_and_close
        queue = new_queue
        native_push(queue, 1, :value)

        assert_same queue, queue.close
        assert_predicate queue, :closed?
        assert_same queue, queue.close
        assert_same queue, queue.clear
        assert_predicate queue, :empty?
        assert_raises(ClosedQueueError) { native_push(queue, 1, :value) }
        assert_raises(ClosedQueueError) { native_pop(queue) }
        assert_raises(ClosedQueueError) { queue.peek }
        assert_raises(ClosedQueueError) { queue.peek_priority }
        assert_raises(ClosedQueueError) { queue.delete(1, :value) }
        assert_raises(ClosedQueueError) { queue.delete_identity(1, :value) }
      end

      def test_gc_compaction_updates_priorities_and_values
        return unless GC.respond_to?(:compact)

        queue = new_queue(capacity: nil)
        256.times.reverse_each do |index|
          priority = share(format("priority-%03d", index))
          value = share(format("value-%03d", index))
          native_push(queue, priority, value)
        end

        if GC.respond_to?(:verify_compaction_references)
          GC.verify_compaction_references(double_heap: true, toward: :empty)
        else
          GC.compact
        end

        256.times do |index|
          assert_equal format("priority-%03d", index), queue.peek_priority
          assert_equal format("value-%03d", index), native_pop(queue)
        end
      end

      def test_lock_is_recovered_after_comparison_exception
        queue = new_queue
        native_push(queue, ComparablePriority.new(1), :first)

        error = assert_raises(RuntimeError) do
          native_push(queue, ComparablePriority.new(2, explode: true), :second)
        end
        assert_equal "comparison exploded", error.message

        queue.clear

        assert native_push(queue, 1, :recovered)
        assert_equal :recovered, native_pop(queue)
      end

      def test_lock_is_recovered_after_equality_exception
        queue = new_queue
        native_push(queue, 1, EqualityBomb.new)

        error = assert_raises(RuntimeError) { queue.delete(1, :probe) }
        assert_equal "equality exploded", error.message
        assert_instance_of EqualityBomb, native_pop(queue)
      end
    end

    class ComparablePriority
      attr_reader :rank

      def initialize(rank, explode: false, reenter: nil, yield_thread: false)
        @rank = rank
        @explode = explode
        @reenter = reenter
        @yield_thread = yield_thread
        freeze
      end

      def <=>(other)
        raise "comparison exploded" if @explode

        @reenter&.peek
        Thread.pass if @yield_thread
        rank <=> other.rank
      end
    end

    class EqualityBomb
      def initialize = freeze

      def ==(_other) = raise("equality exploded")
    end

    class FirstComparisonBomb
      def <=>(_other) = raise "first priority must not be compared with itself"
    end

    class ReverseStringPriority < String
      def <=>(other) = -super
    end

    class HostileStringPriority < String
      attr_reader :snapshot_marker

      def initialize(value)
        super
        @snapshot_marker = Object.new
      end

      def dup = self
      def freeze = self
    end

    class BroadcastBomb
      def initialize(explode_at)
        @calls = Internal::Atom.new(0)
        @explode_at = explode_at
        freeze
      end

      def broadcast
        call = @calls.update { it + 1 }
        raise "broadcast exploded" if call == @explode_at

        call
      end
    end

    class CountingBroadcast
      def initialize(counter)
        @counter = counter
        freeze
      end

      def broadcast = @counter.increment
    end

    class SecondComparisonBomb
      attr_reader :rank

      def initialize(rank)
        @rank = rank
        @calls = Internal::Atom.new(0)
        freeze
      end

      def <=>(other)
        call = @calls.update { it + 1 }
        raise "second comparison exploded" if call == 2

        rank <=> other.rank
      end
    end

    class SecondComparisonFreezer
      attr_reader :calls, :rank

      def initialize(rank, target)
        @rank = rank
        @target = target
        @calls = 0
      end

      def <=>(other)
        @calls += 1
        @target.freeze if @calls == 2
        rank <=> other.rank
      end
    end

    class EqualityFreezer
      def initialize(target)
        @target = target
      end

      def ==(_other)
        @target.freeze
        true
      end
    end

    class ReentrantRespondToSignal
      CALLBACK_KEY = :farce_priority_queue_initialize_signal_callback

      def initialize(counter)
        @counter = counter
        freeze
      end

      def respond_to_missing?(name, include_private = false)
        if name == :broadcast && (callback = Thread.current[CALLBACK_KEY])
          Thread.current[CALLBACK_KEY] = nil
          callback.call
        end
        name == :broadcast || super
      end

      def method_missing(name, ...)
        return @counter.increment if name == :broadcast

        super
      end
    end

    class TestNativePriorityQueueStorage < Test
      include Helpers::InternalTestHelpers

      include PriorityQueueStorageBehavior

      QueueClass = Internal::PriorityQueue

      def test_queue_is_unfrozen_and_ractor_shareable_on_cruby
        queue = queue_class.new

        assert_equal native_unshared_storage?, queue.frozen?
        assert Ractor.shareable?(queue) if RUBY_ENGINE == "ruby"
      end

      def test_unshareable_inputs_are_rejected_on_cruby
        return unless RUBY_ENGINE == "ruby"

        queue = queue_class.new
        assert_raises(Ractor::IsolationError) { native_push(queue, Object.new, :value) }
        assert_raises(Ractor::IsolationError) { native_push(queue, 1, Object.new) }
        assert_raises(Ractor::IsolationError) { queue.delete(1, Object.new) }
        assert_raises(Ractor::IsolationError) { queue.delete_identity(1, Object.new) }
        assert_raises(Ractor::IsolationError) do
          new_queue_with_signal(signal: Object.new)
        end
      end

      def test_signal_protocol_callback_cannot_overwrite_a_recursive_initialization
        queue = queue_class.allocate
        broadcasts = Internal::Counter.new
        signal = ReentrantRespondToSignal.new(broadcasts)
        Thread.current[ReentrantRespondToSignal::CALLBACK_KEY] = proc do
          queue.send(:initialize, capacity: 3)
        end

        error = assert_raises(RuntimeError) do
          initialize_native_storage(queue, signal:)
        end

        assert_match(/already initialized/, error.message)
        assert_equal 3, queue.capacity
        assert native_push(queue, 1, :value)
        assert_equal 0, broadcasts.value,
          "the losing initializer must not install its notification signal"
      ensure
        Thread.current[ReentrantRespondToSignal::CALLBACK_KEY] = nil
      end

      def test_concurrent_initializers_have_one_atomic_winner
        queue = queue_class.allocate
        entered = Thread::Queue.new
        release = Thread::Queue.new
        counters = 2.times.map { Internal::Counter.new }
        signals = counters.map { CountingBroadcast.new(it) }
        capacity_class = Class.new do
          define_method(:initialize) do |value, entered_queue, release_queue|
            @value = value
            @entered = entered_queue
            @release = release_queue
          end
          define_method(:to_int) do
            @entered << true
            @release.pop
            @value
          end
        end
        threads = [3, 5].each_with_index.map do |capacity, index|
          argument = capacity_class.new(capacity, entered, release)
          signal = signals.fetch(index)
          Thread.new do
            result = initialize_native_storage(queue, capacity: argument, signal:)
            [capacity, signal, counters.fetch(index), result]
          rescue StandardError => e
            [capacity, signal, counters.fetch(index), e]
          end
        end
        2.times { Timeout.timeout(5) { entered.pop } }
        2.times { release << true }
        results = threads.map do |thread|
          assert thread.join(5), "concurrent initializer did not finish"
          thread.value
        end

        winner = results.find { |_capacity, _signal, _counter, result| result.equal?(queue) }
        loser = results.find { |_capacity, _signal, _counter, result| result.is_a?(Exception) }

        assert winner, "one initializer must win"
        assert loser, "one initializer must lose"
        assert_instance_of RuntimeError, loser.last
        assert_match(/already initialized/, loser.last.message)
        assert_equal winner.first, queue.capacity
        assert native_push(queue, 1, :value)
        assert_equal 1, winner[2].value
        assert_equal 0, loser[2].value
        assert_equal native_unshared_storage?, queue.frozen?
      ensure
        2.times { release << true } if release
        threads&.each { |thread| thread.kill if thread.alive? }
      end

      def test_notification_failure_leaves_prepared_entries_uncommitted
        # Omitting capacity also verifies that native engines parse the second
        # optional keyword independently rather than silently dropping signal.
        new_bucket = new_queue_with_signal(signal: BroadcastBomb.new(1))
        error = assert_raises(RuntimeError) { native_push(new_bucket, 1, :value) }
        assert_equal "broadcast exploded", error.message
        assert_empty new_bucket

        existing_bucket = new_queue_with_signal(
          capacity: nil,
          signal:   BroadcastBomb.new(2),
        )

        assert native_push(existing_bucket, 1, :first)
        error = assert_raises(RuntimeError) { native_push(existing_bucket, 1, :second) }
        assert_equal "broadcast exploded", error.message
        assert_equal 1, existing_bucket.size
        assert_equal :first, native_pop(existing_bucket)
      end

      def test_native_storage_keeps_its_notification_signal_alive
        calls = Internal::Counter.new
        queue = new_queue_with_ephemeral_signal(calls)

        GC.start
        GC.compact if GC.respond_to?(:compact)

        assert native_push(queue, 1, :value)
        assert_equal 1, calls.value
      end

      def test_new_bucket_comparison_failure_after_notification_is_only_spurious
        signal = Internal::Signal.new
        queue = new_queue_with_signal(capacity: nil, signal:)
        native_push(queue, ComparablePriority.new(1), :first)
        generation = signal.generation

        error = assert_raises(RuntimeError) do
          native_push(queue, SecondComparisonBomb.new(2), :second)
        end
        assert_equal "second comparison exploded", error.message
        assert_operator signal.generation, :>, generation
        assert_equal 1, queue.size
        assert_equal :first, native_pop(queue)
      end

      def test_recursive_comparison_access_raises_instead_of_deadlocking
        queue = queue_class.new
        native_push(queue, ComparablePriority.new(1), :first)
        recursive = ComparablePriority.new(2, reenter: queue)

        assert_raises(ThreadError) { native_push(queue, recursive, :second) }
        queue.clear

        assert native_push(queue, 1, :recovered)
      end

      def test_thread_contention_during_ruby_comparisons
        queue = queue_class.new(capacity: nil)
        threads = 6.times.map do |worker|
          Thread.new do
            250.times do |index|
              rank = (worker * 1_000) + index
              native_push(queue, ComparablePriority.new(rank, yield_thread: true), rank)
            end
          end
        end

        threads.each do |thread|
          assert thread.join(10), "priority-queue worker deadlocked"
          thread.value
        end

        assert_equal 1_500, queue.size
        assert_equal 0, queue.peek_priority.rank
      ensure
        threads&.each { |thread| thread.kill if thread.alive? }
      end

      def test_concurrent_ractor_producers
        return unless RUBY_ENGINE == "ruby"

        queue = queue_class.new(capacity: nil)
        workers = 4.times.map do |worker|
          Ractor.new(queue, worker) do |shared, prefix|
            250.times { |index| shared.push(index % 8, (prefix * 1_000) + index) }
          end
        end
        workers.each { |worker| ractor_value(worker) }

        actual = 1_000.times.map { native_pop(queue) }
        expected = 4.times.flat_map { |worker| 250.times.map { |index| (worker * 1_000) + index } }

        assert_equal expected.sort, actual.sort
        assert_predicate queue, :empty?
      end

      private

      def new_queue_with_ephemeral_signal(calls)
        new_queue_with_signal(signal: CountingBroadcast.new(calls))
      end
    end

    class TestUnsharedPriorityQueueStorage < TestNativePriorityQueueStorage
      QueueClass = Internal::UnsharedPriorityQueue

      def share(value) = value

      undef_method :test_queue_is_unfrozen_and_ractor_shareable_on_cruby
      undef_method :test_unshareable_inputs_are_rejected_on_cruby
      undef_method :test_concurrent_ractor_producers

      def test_queue_uses_the_unshared_storage_freeze_policy
        queue = new_queue

        if native_unshared_storage?
          assert_predicate queue, :frozen?
          refute Ractor.shareable?(queue)
        else
          refute_predicate queue, :frozen?
          assert_raises(TypeError) { queue.freeze }
          refute_predicate queue, :frozen?
        end
      end
    end
  end
end
