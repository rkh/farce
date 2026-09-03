# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A thread-safe, ractor-shareable, first-in-first-out queue.
  #
  # The queue is bounded by default. Producers wait when the queue reaches its
  # capacity, while consumers wait when it is empty.
  class Queue < Abstract::Queue
    include Shareable

    # Create a queue.
    # @param capacity [Integer, nil] the maximum number of values, or nil for an unbounded queue
    def initialize(capacity: 1024)
      @queue = Internal::Queue.new(capacity:)
      super()
    end

    # The maximum number of values, or nil when the queue is unbounded.
    # @return [Integer, nil]
    def capacity = @queue.capacity

    # Remove all values and wake waiting producers.
    # @return [self]
    def clear
      @queue.clear
      self
    end

    # Close the queue and wake all waiters.
    # @return [self]
    def close
      @queue.close
      self
    end

    # Whether the queue is closed.
    # @return [Boolean]
    def closed? = @queue.closed?

    # Whether the queue contains no values.
    # @return [Boolean]
    def empty? = size.zero?

    # The approximate number of execution contexts waiting to push or pop.
    # @return [Integer]
    def num_waiting = @queue.num_waiting

    # Remove the oldest value, waiting while the queue is empty.
    # @param non_block [Boolean] whether to raise instead of waiting when empty
    # @param timeout [Numeric, nil] maximum number of seconds to wait
    # @yield called when the timeout expires
    # @raise [ThreadError] when the queue is empty and non_block is true
    # @return [BasicObject, nil] the value or the fallback result
    def pop(non_block = false, timeout: nil, &fallback) # rubocop:disable Style/OptionalBooleanParameter
      return try_pop { raise ThreadError, "queue empty" } if non_block

      @queue.pop(timeout:, &fallback)
    end

    # Add a value, waiting while a bounded queue is full.
    # @param value [BasicObject] the value to add
    # @param non_block [Boolean] whether to raise instead of waiting when full
    # @param timeout [Numeric, nil] maximum number of seconds to wait
    # @raise [ThreadError] when the queue is full and non_block is true
    # @return [Boolean] whether the value was added
    def push(value, non_block = false, timeout: nil) # rubocop:disable Style/OptionalBooleanParameter
      if non_block
        return true if @queue.push(value, timeout: 0)

        raise ThreadError, "queue full"
      end

      @queue.push(value, timeout:)
    end

    # Try to remove the oldest value without waiting.
    # @yield called when the queue is empty
    # @return [BasicObject, nil] the value or the fallback result
    def try_pop
      empty = false
      result = @queue.pop(timeout: 0) { empty = true }
      return result unless empty

      block_given? ? yield : nil
    end

    # Try to add a value without waiting.
    # @param value [BasicObject] the value to add
    # @yield called when the queue is full
    # @return [Boolean, BasicObject] true, or the fallback result when full
    def try_push(value)
      return true if @queue.push(value, timeout: 0)

      block_given? ? yield : false
    end

    # The number of values currently stored.
    # @return [Integer]
    def size = @queue.size

    # Wait until a value is available without removing it.
    # @param timeout [Numeric, nil] maximum number of seconds to wait
    # @return [Boolean] whether a value became available
    def wait_pop(timeout: nil) = @queue.wait_pop(timeout:)

    # Wait until capacity is available without adding a value.
    # @param timeout [Numeric, nil] maximum number of seconds to wait
    # @return [Boolean] whether capacity became available
    def wait_push(timeout: nil) = @queue.wait_push(timeout:)

    private

    def initialize_copy(_other)
      raise TypeError, "queues cannot be copied"
    end
  end
end
