# frozen_string_literal: true

require_relative "../../setup"

module Farce
  module Internal
    class TestPriorityQueueOperations < Test
      Match = Data.define(:target) do
        def ===(value) = value == target
      end
      ExplodingMatch = Data.define(:message) do
        def ===(_value) = raise(message)
      end
      ReentrantMatch = Data.define(:queue) do
        def ===(_value) = queue.pop
      end
      ExplodingPriority = Data.define(:rank) do
        def <=>(_other) = raise("comparison failed")
      end

      def test_pop_before_is_inclusive_and_preserves_nil_false_and_fifo_ties
        queue = queue_class.new
        queue.push(2, :future)
        queue.push(1, nil)
        queue.push(1, false)
        queue.push(1, :last)

        assert_equal :not_due, queue.pop_before(0) { :not_due }
        assert_equal 4, queue.size
        assert_nil queue.pop_before(1) { flunk "nil is a payload" }
        refute queue.pop_before(1) { flunk "false is a payload" }
        assert_equal :last, queue.pop_before(1)
        assert_equal :not_due, queue.pop_before(1) { :not_due }
        assert_equal :future, queue.pop_before(2)
        assert_equal :empty, queue.pop_before(3) { :empty }
      end

      def test_pop_before_releases_the_lock_on_comparison_failure
        queue = queue_class.new
        queue.push(ExplodingPriority.new(1), :kept)

        assert_raises(RuntimeError) { queue.pop_before(ExplodingPriority.new(2)) }
        assert_equal :kept, queue.pop
        assert_predicate queue, :empty?
      end

      def test_delete_match_removes_only_the_oldest_match_at_the_exact_priority
        queue = queue_class.new
        queue.push(1, :target)
        queue.push(2, :other)
        queue.push(2, :target)
        queue.push(2, :target)

        refute queue.delete_match(3, Match.new(:target))
        assert queue.delete_match(2, Match.new(:target))
        assert_equal %i[target other target], Array.new(3) { queue.pop }
      end

      def test_match_failures_and_reentrancy_leave_values_and_lock_intact
        queue = queue_class.new
        queue.push(1, :kept)

        assert_raises(RuntimeError) { queue.delete_match(1, ExplodingMatch.new("match failed")) }
        assert_raises(ThreadError) { queue.delete_match(1, ReentrantMatch.new(queue)) }
        assert_equal :kept, queue.pop
        assert_predicate queue, :empty?
      end

      def test_new_operations_observe_close
        queue = queue_class.new
        queue.close

        assert_raises(ClosedQueueError) { queue.pop_before(1) }
        assert_raises(ClosedQueueError) { queue.delete_match(1, Match.new(nil)) }
      end

      def test_float_insertions_and_due_pops_match_a_sorted_reference
        queue = queue_class.new
        random = Random.new(173)
        expected = []

        2000.times do |id|
          priority = random.rand(40).fdiv(4)
          if random.rand(3).zero?
            expected.sort_by! { |key, sequence| [key, sequence] }
            due = expected.first && expected.first[0] <= priority
            value = due ? expected.shift[1] : :not_due

            assert_equal value, queue.pop_before(priority) { :not_due }
          else
            queue.push(priority, id)
            expected << [priority, id]
          end
        end

        expected.sort_by! { |key, sequence| [key, sequence] }

        assert_equal expected.map(&:last), Array.new(queue.size) { queue.pop }
        assert_predicate queue, :empty?
      end

      def test_float_fast_path_transitions_and_special_values
        queue = queue_class.new
        priorities = [1.5, -0.0, 0.0, -Float::INFINITY, Float::INFINITY, 2, -1.5]
        priorities.each_with_index { |priority, id| queue.push(priority, id) }
        expected = priorities.each_with_index.sort_by { |priority, id| [priority, id] }.map(&:last)

        assert_equal expected, Array.new(queue.size) { queue.pop_before(Float::INFINITY) }
        queue.push(2.5, :later)
        queue.push(1.5, :earlier)

        assert_equal :earlier, queue.pop_before(1.5)
        assert_equal :later, queue.pop_before(2.5)
      end

      private def queue_class = PriorityQueue
    end

    class TestUnsharedPriorityQueueOperations < TestPriorityQueueOperations
      private def queue_class = UnsharedPriorityQueue
    end

    if Internal.native_ractors?
      class TestUnsharedPriorityQueueSignalOperations < TestPriorityQueueOperations
        private def queue_class
          Class.new(UnsharedPriorityQueue) do
            def initialize
              super(signal: UnsharedSignal.new)
            end
          end
        end
      end
    end
  end
end
