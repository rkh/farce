# frozen_string_literal: true

jvm = RUBY_ENGINE == "jruby" || (RUBY_ENGINE == "truffleruby" && !TruffleRuby.native?)
return unless jvm

require_relative "../../setup"

module Farce
  module Internal
    class JVMEqualValue
      attr_reader :group, :tag

      def initialize(group, tag)
        @group = group
        @tag = tag
      end

      def ==(other) = other.is_a?(JVMEqualValue) && group == other.group
    end

    class JVMComparablePriority
      attr_reader :rank

      def initialize(rank, error: nil, reenter: nil, freeze_target: nil, yield_fiber: false)
        @rank = rank
        @error = error
        @reenter = reenter
        @freeze_target = freeze_target
        @yield_fiber = yield_fiber
      end

      def <=>(other)
        raise @error if @error
        @reenter&.peek
        @freeze_target&.freeze
        Fiber.scheduler&.kernel_sleep(0.01) if @yield_fiber
        rank <=> other.rank
      end
    end

    class JVMDelayedComparisonError
      attr_reader :rank

      def initialize(rank, raise_at: nil)
        @rank = rank
        @raise_at = raise_at
        @comparisons = 0
      end

      def <=>(other)
        @comparisons += 1
        raise "delayed comparison exploded" if @comparisons == @raise_at

        rank <=> other.rank
      end
    end

    class JVMFlippingPriority
      def initialize = @comparisons = 0

      def <=>(_other)
        @comparisons += 1
        @comparisons == 1 ? 1 : 0
      end
    end

    class JVMPoisonablePriority
      attr_accessor :poisoned
      attr_reader :rank

      def initialize(rank)
        @rank = rank
        @poisoned = false
      end

      def <=>(other)
        raise "ghost compared" if poisoned

        rank <=> other.rank
      end
    end

    class JVMFractionalPriority
      attr_reader :rank

      def initialize(rank) = @rank = rank

      def <=>(other) = (rank <=> other.rank) / 2.0
    end

    class JVMCoercingPriority < Numeric
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

    class JVMEqualityBomb
      def ==(_other) = raise "equality exploded"
    end

    class JVMFirstPriorityComparisonBomb
      def <=>(_other) = raise "first priority must not be compared with itself"
    end

    class JVMReverseStringPriority < String
      def <=>(other) = -super
    end

    class JVMHostileStringPriority < String
      attr_reader :snapshot_marker

      def initialize(value)
        super
        @snapshot_marker = Object.new
      end

      def dup = self
      def freeze = self
    end

    JVMOverriddenIdentity = Class.new do
      define_method(:__id__) { raise "overridden __id__ must not be called" } # rubocop:disable Naming/MethodName
    end

    JVMOverriddenEqual = Class.new do
      def initialize(identity_answer) = (@identity_answer = identity_answer)
      def equal?(_other) = @identity_answer
    end

    class JVMQueueTestSignal
      attr_reader :generation
      attr_accessor :raise_next, :throw_next

      def initialize
        @generation = 0
        @raise_next = false
        @throw_next = false
      end

      def broadcast
        if raise_next
          self.raise_next = false
          raise "broadcast exploded"
        end
        if throw_next
          self.throw_next = false
          throw :jvm_queue_signal, :thrown
        end

        @generation += 1
      end
    end

    class JVMBlockingQueueTestSignal
      attr_reader :entered, :release

      def initialize
        @entered = Thread::Queue.new
        @release = Thread::Queue.new
        @block_next = true
      end

      def broadcast
        return unless @block_next

        @block_next = false
        entered << true
        release.pop
      end
    end

    class TestJVMPriorityQueueStorage < Test
      QUEUES = [Internal::PriorityQueue].freeze

      def build_storage(capacity: 1_024, signal: nil)
        queue = Internal::PriorityQueue.allocate
        queue.send(:initialize, capacity:, signal:)
        queue
      end

      def try_push(queue, priority, value) = queue.push(priority, value)
      def try_pop(queue, &) = queue.pop(&)

      QUEUES.each do |queue_class|
        label = queue_class.name.split("::").last

        define_method("test_#{label}_capacity_fifo_nil_and_fallbacks") do
          queue = queue_class.new

          assert_nil queue.capacity
          assert_equal 1_024, queue_class.new(capacity: 1_024).capacity
          assert_raises(ArgumentError) { queue_class.new(capacity: 0) }
          assert_raises(ArgumentError) { queue_class.new(capacity: -1) }
          assert_raises(TypeError) { queue_class.new(capacity: "2") }
          invalid_capacity = Object.new
          invalid_capacity.define_singleton_method(:to_int) { 2.5 }
          assert_raises(TypeError) { queue_class.new(capacity: invalid_capacity) }
          hostile_capacity = Object.new
          hostile_capacity.define_singleton_method(:is_a?) { |_class| true }
          hostile_capacity.define_singleton_method(:positive?) { true }
          assert_raises(TypeError) { queue_class.new(capacity: hostile_capacity) }

          queue = queue_class.new(capacity: 4)

          assert queue.push(3, :later)
          assert queue.push(1, nil)
          assert queue.push(1, :second)
          assert queue.push(2, :middle)
          refute try_push(queue, 0, :full)
          assert_nil queue.peek
          assert_equal 1, queue.peek_priority
          assert_nil queue.pop
          assert_equal :second, queue.pop
          assert_equal :middle, queue.pop
          assert_equal :later, queue.pop
          assert_predicate queue, :empty?

          assert_equal(:fallback, queue.pop do
            queue.push(1, :from_fallback)
            :fallback
          end)
          assert_equal :from_fallback, queue.pop
          assert_equal(:peek, queue.peek { :peek })
          assert_equal(:priority, queue.peek_priority { :priority })
        end

        define_method("test_#{label}_initialization_is_transactional_and_one_shot") do
          queue = queue_class.allocate
          recursive_capacity = Object.new
          recursive_capacity.define_singleton_method(:to_int) do
            queue.send(:initialize, capacity: 3)
            5
          end

          error = assert_raises(RuntimeError) do
            queue.send(:initialize, capacity: recursive_capacity)
          end
          assert_match(/already initialized/, error.message)
          assert_equal 3, queue.capacity
          assert queue.push(1, :inner)
          assert_equal :inner, queue.pop
          assert_raises(RuntimeError) { queue.send(:initialize, capacity: 7) }

          frozen_queue = queue_class.allocate
          frozen_capacity = Object.new
          frozen_capacity.define_singleton_method(:to_int) do
            frozen_queue.freeze
            1
          end
          assert_raises(FrozenError) do
            frozen_queue.send(:initialize, capacity: frozen_capacity)
          end
          assert_raises(RuntimeError) { frozen_queue.size }
          assert_raises(RuntimeError) { frozen_queue.capacity }
        end

        define_method("test_#{label}_preserves_the_sign_of_fractional_comparisons") do
          queue = queue_class.new(capacity: nil)
          queue.push(JVMFractionalPriority.new(2), :second)
          queue.push(JVMFractionalPriority.new(1), :first)

          assert_equal :first, queue.pop
          assert_equal :second, queue.pop
        end

        define_method("test_#{label}_maximum_priority_endpoint_preserves_fifo_ties") do
          queue = queue_class.new(capacity: nil)
          queue.push(1, :earliest)
          queue.push(3, :first)
          queue.push(3, :second)
          queue.push(2, :middle)

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

        define_method("test_#{label}_first_priority_does_not_require_self_comparison") do
          priority = JVMFirstPriorityComparisonBomb.new
          queue = queue_class.new(capacity: nil)

          assert queue.push(priority, :value)
          assert_equal 1, queue.size
          assert_same priority, queue.peek_priority
          assert_equal :value, queue.pop
        end

        define_method("test_#{label}_string_subclass_uses_its_overridden_comparator") do
          queue = queue_class.new(capacity: nil)
          queue.push(JVMReverseStringPriority.new("a"), :a)
          queue.push(JVMReverseStringPriority.new("b"), :b)

          assert_equal :b, queue.pop
          assert_equal :a, queue.pop
        end

        define_method("test_#{label}_float_ordering_and_nan_comparison_semantics") do
          queue = queue_class.new(capacity: nil)
          queue.push(2.5, :later)
          queue.push(-Float::INFINITY, :first)
          queue.push(2.5, :tie)

          assert_equal :first, queue.pop
          assert_equal :later, queue.pop
          assert_equal :tie, queue.pop

          nan = Float::NAN

          assert queue.push(nan, :nan)
          assert_raises(ArgumentError) { queue.push(1.0, :incomparable) }
          assert_equal 1, queue.size
          assert_predicate queue.peek_priority, :nan?
        end

        define_method("test_#{label}_does_not_replace_a_bucket_between_lookup_and_insert") do
          queue = queue_class.new(capacity: nil)
          queue.push(JVMComparablePriority.new(1), :old)

          assert queue.push(JVMFlippingPriority.new, :new)
          assert_equal 2, queue.size
          assert_equal :old, queue.pop
          assert_equal :new, queue.pop
          assert_predicate queue, :empty?
        end

        define_method("test_#{label}_equality_and_identity_are_distinct") do
          first = JVMEqualValue.new(:same, :first)
          target = JVMEqualValue.new(:same, :target)

          equality_queue = queue_class.new
          equality_queue.push(1, first)
          equality_queue.push(1, target)

          assert equality_queue.delete(1, target)
          assert_same target, equality_queue.pop

          identity_queue = queue_class.new
          identity_queue.push(1, first)
          identity_queue.push(1, target)

          assert identity_queue.delete_identity(1, target)
          assert_same first, identity_queue.pop
          refute identity_queue.delete_identity(1, target)

          identity_queue.push(1, first)
          identity_queue.push(2, target)

          refute identity_queue.delete_identity(1, target)
          assert_same first, identity_queue.pop
          assert_same target, identity_queue.pop
        end

        define_method("test_#{label}_close_clear_copy_and_exception_recovery") do
          queue = queue_class.new(capacity: nil)
          queue.push(JVMComparablePriority.new(1), JVMEqualityBomb.new)

          comparison = JVMComparablePriority.new(2, error: "comparison exploded")
          error = assert_raises(RuntimeError) { queue.push(comparison, :value) }
          assert_equal "comparison exploded", error.message

          error = assert_raises(RuntimeError) { queue.delete(JVMComparablePriority.new(1), :probe) }
          assert_equal "equality exploded", error.message
          assert_instance_of JVMEqualityBomb, queue.pop

          queue.push(1, :discarded)

          assert_same queue, queue.close
          assert_same queue, queue.close
          assert_predicate queue, :closed?
          assert_same queue, queue.clear
          assert_predicate queue, :empty?
          assert_raises(ClosedQueueError) { queue.push(1, :value) }
          assert_raises(ClosedQueueError) { queue.pop }
          assert_raises(ClosedQueueError) { queue.peek }
          assert_raises(ClosedQueueError) { queue.peek_priority }
          assert_raises(ClosedQueueError) { queue.delete(1, :value) }
          assert_raises(ClosedQueueError) { queue.delete_identity(1, :value) }
          assert_raises(TypeError) { queue_class.new.dup }
        end

        define_method("test_#{label}_randomized_differential") do
          random = Random.new(48_190)
          queue = queue_class.new(capacity: nil)
          model = []
          sequence = 0

          5_000.times do |step|
            case random.rand(100)
            when 0...45
              priority = random.rand(-8..8)
              value = if random.rand(8).zero?
                        nil
                      else
                        JVMEqualValue.new(random.rand(6), [step, random.rand(4)])
                      end

              assert queue.push(priority, value), "push step=#{step}"
              model << [priority, value, sequence]
              sequence += 1
            when 45...65
              expected = model.min_by { |priority, _value, inserted| [priority, inserted] }
              actual = queue.pop { :empty }
              if expected
                model.delete(expected)
                if expected[1].nil?
                  assert_nil actual, "pop step=#{step}"
                else
                  assert_same expected[1], actual, "pop step=#{step}"
                end
              else
                assert_equal :empty, actual, "empty pop step=#{step}"
              end
            when 65...80
              if !model.empty? && random.rand < 0.8
                priority, value, = model.sample(random: random)
                probe = value.nil? ? nil : JVMEqualValue.new(value.group, :probe)
              else
                priority = random.rand(-8..8)
                probe = JVMEqualValue.new(:missing, step)
              end
              index = model.index { it[0] == priority && it[1] == probe }

              assert_equal !index.nil?, queue.delete(priority, probe), "equality delete step=#{step}"
              model.delete_at(index) if index
            when 80...95
              if !model.empty? && random.rand < 0.8
                priority, value, = model.sample(random: random)
              else
                priority = random.rand(-8..8)
                value = Object.new
              end
              index = model.index { it[0] == priority && it[1].equal?(value) }

              assert_equal !index.nil?, queue.delete_identity(priority, value), "identity delete step=#{step}"
              model.delete_at(index) if index
            else
              assert_same queue, queue.clear
              model.clear
            end

            assert_equal model.size, queue.size, "size step=#{step}"
            expected = model.min_by { |priority, _value, inserted| [priority, inserted] }
            if expected
              assert_equal expected[0], queue.peek_priority, "priority step=#{step}"
              if expected[1].nil?
                assert_nil queue.peek, "peek step=#{step}"
              else
                assert_same expected[1], queue.peek, "peek step=#{step}"
              end
            else
              assert_nil queue.peek_priority, "empty priority step=#{step}"
              assert_equal :empty, queue.peek { :empty }, "empty peek step=#{step}"
            end
          end
        end
      end

      def test_lazy_identity_index_tracks_repeated_objects
        queue = Internal::PriorityQueue.new(capacity: nil)
        repeated = Object.new
        values = Array.new(40) { Object.new }
        values[5] = repeated
        values[35] = repeated
        values.each { queue.push(1, it) }

        assert queue.delete_identity(1, repeated)
        expected = values.dup
        expected.delete_at(5)
        expected.each { assert_same it, queue.pop }

        assert_predicate queue, :empty?
      end

      def test_initialization_uses_primitive_freeze
        queue_class = Class.new(Internal::PriorityQueue) do
          def freeze = raise "overrideable freeze must not run"
        end

        queue = queue_class.new(capacity: nil)

        assert_predicate queue, :frozen?
        assert queue.push(1, :value)
        assert_equal :value, queue.pop
      end

      def test_uses_a_primitive_frozen_string_snapshot
        queue = Internal::PriorityQueue.new(capacity: nil)
        original = JVMHostileStringPriority.new("middle")
        queue.push(original, :middle)
        stored = queue.peek_priority

        original.replace("zzzz")
        queue.push(JVMHostileStringPriority.new("alpha"), :alpha)
        queue.push(JVMHostileStringPriority.new("omega"), :omega)

        refute_same original, stored
        assert_instance_of JVMHostileStringPriority, stored
        assert_same original.snapshot_marker, stored.snapshot_marker
        assert_predicate stored, :frozen?
        assert_equal %i[alpha middle omega], [queue.pop, queue.pop, queue.pop]
      end

      def test_uses_the_vm_identity_primitive
        queue = Internal::PriorityQueue.new(capacity: nil)
        value = JVMOverriddenIdentity.new
        40.times { queue.push(1, Object.new) }
        queue.push(1, value)

        assert queue.delete_identity(1, value)
        refute queue.delete_identity(1, value)
        assert_equal 40, queue.size
      end

      def test_identity_deletion_bypasses_an_overridden_equal
        primitive_equal = BasicObject.instance_method(:equal?)
        impostor = JVMOverriddenEqual.new(true)
        target = Object.new
        queue = Internal::PriorityQueue.new(capacity: nil)
        queue.push(1, impostor)
        queue.push(1, target)

        assert queue.delete_identity(1, target)
        assert primitive_equal.bind_call(impostor, queue.pop)

        self_denial = JVMOverriddenEqual.new(false)
        40.times { queue.push(1, Object.new) }
        queue.push(1, self_denial)

        assert queue.delete_identity(1, self_denial)
        assert_equal 40, queue.size
      end

      def test_rejects_recursive_comparison_without_deadlock
        queue = Internal::PriorityQueue.new
        queue.push(JVMComparablePriority.new(1), :first)
        recursive = JVMComparablePriority.new(2, reenter: queue)

        assert_raises(ThreadError) { queue.push(recursive, :second) }
        queue.clear

        assert queue.push(1, :recovered)
        assert_equal :recovered, queue.pop
      end

      def test_recursive_guard_bypasses_an_overridden_thread_equal
        queue = Internal::PriorityQueue.new
        queue.push(JVMComparablePriority.new(1), :first)
        recursive = JVMComparablePriority.new(2, reenter: queue)
        worker = Thread.new do
          Thread.current.define_singleton_method(:equal?) { |_other| false }
          queue.push(recursive, :second)
        rescue StandardError => e
          e
        end

        assert worker.join(2), "recursive operation did not finish"
        assert_instance_of ThreadError, worker.value
        assert_equal :first, queue.pop
        assert_predicate queue, :empty?
      ensure
        worker&.kill if worker&.alive?
      end

      def test_recovers_its_java_lock_after_async_cancellation
        started = Thread::Queue.new
        priority_class = Class.new do
          attr_reader :rank

          define_method(:initialize) do |rank, signal|
            @rank = rank
            @signal = signal
          end
          define_method(:<=>) do |other|
            @signal << true
            sleep 10
            rank <=> other.rank
          end
        end
        queue = Internal::PriorityQueue.new(capacity: nil)
        queue.push(JVMComparablePriority.new(1), :first)
        cancellation = Class.new(StandardError)
        worker = Thread.new do
          queue.push(priority_class.new(2, started), :cancelled)
        rescue StandardError => e
          e
        end
        started.pop
        worker.raise(cancellation, "cancel comparison")

        assert worker.join(2), "cancelled comparator did not exit"
        assert_instance_of cancellation, worker.value
        assert_same queue, queue.clear
        assert queue.push(1, :recovered)
        assert_equal :recovered, queue.pop
      ensure
        worker&.kill if worker&.alive?
      end

      def test_parallel_producers_and_deleters
        queue = Internal::PriorityQueue.new(capacity: nil)
        writers = 6.times.map do |worker|
          Thread.new do
            400.times do |index|
              queue.push(index % 16, (worker * 10_000) + index)
            end
          end
        end
        writers.each(&:value)

        assert_equal 2_400, queue.size

        deleters = 6.times.map do |worker|
          Thread.new do
            200.times do |index|
              value = (worker * 10_000) + index
              raise "lost #{value}" unless queue.delete_identity(index % 16, value)
            end
          end
        end
        deleters.each(&:value)

        assert_equal 1_200, queue.size

        actual = Array.new(1_200) { queue.pop }
        expected = 6.times.flat_map do |worker|
          200.upto(399).map { (worker * 10_000) + it }
        end

        assert_equal expected.sort, actual.sort
        assert_predicate queue, :empty?
      end

      def test_jruby_scheduler_contention_fails_safely_instead_of_stranding_the_thread
        return unless RUBY_ENGINE == "jruby"
        return unless Fiber.respond_to?(:set_scheduler)

        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        queue = Internal::PriorityQueue.new(capacity: nil)
        queue.push(JVMComparablePriority.new(1), :one)
        events = []

        Fiber.schedule do
          events << :owner_started
          queue.push(JVMComparablePriority.new(2, yield_fiber: true), :two)
          events << :owner_finished
        end
        Fiber.schedule do
          events << :contender_started
          queue.size
        rescue ThreadError
          events << :safe_failure
        end
        Fiber.set_scheduler(nil)

        assert_equal %i[owner_started contender_started safe_failure owner_finished], events
        assert_equal 2, queue.size
      ensure
        Fiber.set_scheduler(nil) if Fiber.respond_to?(:scheduler) && Fiber.scheduler
      end

      def test_storage_notifies_exactly_for_committed_changes
        signal = JVMQueueTestSignal.new
        queue = build_storage(capacity: 1, signal:)

        assert_raises(TypeError) { Internal::PriorityQueue.new(signal: Object.new) }

        assert try_push(queue, 1, :value)
        assert_equal 1, signal.generation
        refute try_push(queue, 2, :full)
        assert_equal 1, signal.generation
        refute queue.delete(1, :missing)
        assert_equal 1, signal.generation
        assert_equal :value, try_pop(queue)
        assert_equal 2, signal.generation
        assert_nil try_pop(queue)
        assert_equal 2, signal.generation

        assert_same queue, queue.clear
        assert_equal 3, signal.generation
        assert_same queue, queue.close
        assert_equal 4, signal.generation
        assert_same queue, queue.close
        assert_equal 5, signal.generation
      end

      def test_storage_broadcast_failure_cannot_publish_a_mutation
        signal = JVMQueueTestSignal.new
        signal.raise_next = true
        queue = build_storage(capacity: nil, signal:)

        error = assert_raises(RuntimeError) { try_push(queue, 1, :invisible) }
        assert_equal "broadcast exploded", error.message
        assert_predicate queue, :empty?
        assert_nil try_pop(queue)

        assert try_push(queue, 1, :visible)
        assert_equal :visible, try_pop(queue)
        assert_predicate queue, :empty?
      end

      def test_storage_removes_a_new_priority_bucket_after_broadcast_failure
        signal = JVMQueueTestSignal.new
        signal.raise_next = true
        queue = build_storage(capacity: nil, signal:)
        failed_priority = JVMPoisonablePriority.new(1)

        assert_raises(RuntimeError) { try_push(queue, failed_priority, :invisible) }
        failed_priority.poisoned = true

        assert try_push(queue, JVMPoisonablePriority.new(2), :visible)
        assert_equal :visible, try_pop(queue)
        assert_predicate queue, :empty?
      end

      def test_storage_nonlocal_signal_exit_rolls_back_the_prepared_entry_and_index
        signal = JVMQueueTestSignal.new
        queue = build_storage(capacity: nil, signal:)
        values = Array.new(40) { Object.new }
        values.each { try_push(queue, 1, it) }
        removed = values.delete_at(10)

        assert queue.delete_identity(1, removed), "prime the lazy identity index"

        signal.throw_next = true
        result = catch(:jvm_queue_signal) do
          try_push(queue, 1, :invisible)
          :unexpected_return
        end

        assert_equal :thrown, result
        assert_equal values.length, queue.size
        values.each { assert_same it, try_pop(queue) }

        assert_predicate queue, :empty?
      end

      def test_storage_defers_async_cancellation_until_after_notified_commit
        signal = JVMBlockingQueueTestSignal.new
        queue = build_storage(capacity: nil, signal:)
        cancellation = Class.new(StandardError)
        worker = Thread.new do
          try_push(queue, 1, :committed)
        rescue Exception => e # rubocop:disable Lint/RescueException
          e
        end

        signal.entered.pop
        worker.raise(cancellation, "cancel notification")
        signal.release << true

        assert worker.join(2), "cancelled notification did not exit"
        assert_instance_of cancellation, worker.value
        assert_equal 1, queue.size
        assert_equal :committed, try_pop(queue)
        assert_predicate queue, :empty?
      ensure
        signal&.release&.push(true)
        worker&.kill if worker&.alive?
      end

      def test_storage_is_not_corrupted_by_a_late_comparison_exception
        queue = Internal::PriorityQueue.new(capacity: nil)
        15.times { |rank| queue.push(JVMDelayedComparisonError.new(rank), rank) }
        exploding = JVMDelayedComparisonError.new(-1, raise_at: 3)

        error = assert_raises(RuntimeError) { queue.push(exploding, :bad) }
        assert_equal "delayed comparison exploded", error.message
        assert_equal 15, queue.size
        assert_equal((0...15).to_a, 15.times.map { queue.pop })
        assert_predicate queue, :empty?
      end

      def test_single_production_class_exposes_the_primitive_contract
        queue = Internal::PriorityQueue.new

        assert_instance_of Internal::PriorityQueue, queue
        assert_equal Object, Internal::PriorityQueue.superclass
        assert_predicate queue, :frozen?
        assert_respond_to queue, :push
        assert_respond_to queue, :pop
        assert Internal::PriorityQueue.private_method_defined?(:initialize)
      end
    end
  end
end
