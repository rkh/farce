# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A thread-safe, ractor-shareable priority queue. Values with the same priority are removed in
  # insertion order.
  class PriorityQueue < Abstract::Queue
    include Internal::BlockingPriorityQueue
    include Shareable

    # @return [BasicObject] the priority used when none is passed to push
    attr_reader :default_priority

    # @return [:ascending, :descending] the priority order
    attr_reader :order

    # @param capacity [Integer, nil] the maximum number of values, or nil for
    #   an unbounded queue
    # @param default_priority [BasicObject] the priority used when push or
    #   try_push is called without an explicit priority
    # @param order [:ascending, :descending] the priority order
    def initialize(capacity: nil, default_priority: 0, order: :ascending)
      @order            = normalize_order(order)
      @default_priority = default_priority
      super(capacity:, reverse_order: @order == :descending)
    end

    # Return the next value without removing it.
    def peek(&) = @reverse_order ? @queue.peek_last(&) : @queue.peek(&)

    # Remove the oldest value at the lowest or highest priority, depending on {#order}, waiting when empty.
    def pop(non_block = false, timeout: nil) # rubocop:disable Style/OptionalBooleanParameter
      return try_pop { raise ThreadError, "queue empty" } if non_block
      deadline = timeout_at(timeout)

      while true
        empty   = false
        result  = pop_once do
          empty = true
          UNDEFINED
        end
        return result unless empty

        remaining = remaining_timeout(deadline)
        return block_given? ? yield : nil unless wait_pop(timeout: remaining)
      end
    end

    # Add a value, waiting for capacity when the queue is bounded and full.
    # @param value [BasicObject] the value to add
    # @param non_block [Boolean] whether to raise an exception when the queue is at capacity
    # @param priority [BasicObject] the value used to order the entry
    # @param timeout [Numeric, nil] maximum number of seconds to wait
    # @raise [ThreadError] when the queue is at capacity and non_block is true
    # @return [Boolean] whether the value was added
    def push(value, non_block = false, priority: default_priority, timeout: nil) # rubocop:disable Style/OptionalBooleanParameter
      push_to_storage(priority, non_block, value, timeout:)
    end

    # Try to remove the oldest value at the lowest priority without waiting.
    def try_pop(&) = @reverse_order ? @queue.pop_last(&) : @queue.pop(&)

    # Try to add a value without waiting.
    # @param value [BasicObject] the value to add
    # @param priority [BasicObject] the value used to order the entry
    # @yield called when the queue is at capacity
    # @return [Boolean, BasicObject] true, or the fallback result when full
    def try_push(value, priority: default_priority)
      return true if @queue.push(priority, value)

      block_given? ? yield : false
    end

    # Return the next priority without removing it.
    # @yield called when the queue is empty
    # @return [BasicObject, nil] the priority or the fallback result
    def first_priority(&) = @reverse_order ? @queue.peek_last_priority(&) : @queue.peek_priority(&)

    # Return the last priority without removing it.
    # @yield called when the queue is empty
    # @return [BasicObject, nil] the priority or the fallback result
    def last_priority(&) = @reverse_order ? @queue.peek_priority(&) : @queue.peek_last_priority(&)

    # Delete the oldest matching value at the exact priority.
    # @param value [BasicObject] the value to delete
    # @param priority [BasicObject] the exact priority to search
    # @param compare_by_identity [Boolean] compare values by identity instead of equality
    # @return [Boolean] whether a value was deleted
    def delete(value, priority:, compare_by_identity: false)
      if compare_by_identity
        @queue.delete_identity(priority, value)
      else
        @queue.delete(priority, value)
      end
    end

    # Wait until a value is available without removing it.
    def wait_pop(timeout: nil) = wait(timeout) { size.positive? }

    private

    def normalize_order(order)
      return :ascending if :ascending.equal?(order)
      return :descending if :descending.equal?(order)

      raise ArgumentError, "order must be :ascending or :descending"
    end
  end
end
