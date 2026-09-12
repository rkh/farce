# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Shared blocking wrapper behavior for the public priority-based queues.
    module BlockingPriorityQueue
      # Remove all values and wake waiters.
      def clear
        @queue.clear
        self
      end

      # Close the queue and wake waiters.
      def close
        @queue.close
        self
      end

      # Stop new pushes and close after the final value is removed.
      def seal
        @queue.seal
        self
      end

      # Wait until capacity is available without adding a value.
      def wait_push(timeout: nil)
        raise_unwritable if sealed?
        return true unless capacity

        wait(timeout) do
          raise_unwritable if sealed?
          size < capacity
        end
      end

      # The approximate number of waiting execution contexts.
      def num_waiting = @signal.num_waiting

      Internal.delegate(
        self, :@queue, :age_tracking?, :capacity, :closed?, :empty?, :generation,
        :oldest_age, :oldest_enqueued_at, :sealed?, :size,
      )

      private

      def initialize_copy(_other)
        raise TypeError, "priority queues cannot be copied"
      end

      def initialize(capacity:, reverse_order: false, track_age: false)
        @reverse_order = reverse_order
        @signal        = queue_signal
        @queue         = queue_storage_class.new(capacity:, signal: @signal, track_age:)
        super()
      end

      def queue_storage_class = Internal::PriorityQueue
      def queue_signal = Signal.new

      def delete_from_storage(priority, value, compare_by_identity:)
        if compare_by_identity
          @queue.delete_identity(priority, value)
        else
          @queue.delete(priority, value)
        end
      end

      def push_to_storage(priority, non_block, value, timeout:)
        deadline = timeout_at(timeout) unless timeout.nil?

        while true
          return true if @queue.push(priority, value)
          raise ThreadError, "queue full" if non_block
          return false unless wait_push(timeout: remaining_timeout(deadline))
        end
      end

      def normalize_timeout(timeout)
        return nil if timeout.nil?

        timeout = Float(timeout)
        raise ArgumentError, "timeout must be non-negative" if timeout.negative?
        raise ArgumentError, "timeout must be finite" unless timeout.finite?
        raise ArgumentError, "timeout must be a number" if timeout.nan?

        timeout
      end

      def wait(timeout)
        deadline = timeout_at(timeout)

        while true
          generation = @signal.generation
          raise ::Farce::ClosedQueueError, "queue is closed" if closed?
          return true if yield
          return false unless @signal.wait(generation, timeout: remaining_timeout(deadline))
        end
      end

      def raise_unwritable
        closed = closed?
        error = closed ? ::Farce::ClosedQueueError : ::Farce::SealedQueueError
        raise error, closed ? "queue is closed" : "queue is sealed"
      end

      def timeout_at(timeout)
        Clock.timeout(normalize_timeout(timeout)) unless timeout.nil?
      end

      def remaining_timeout(timeout_at)
        return unless timeout_at
        timeout = timeout_at - Clock.now
        timeout.positive? ? timeout : 0
      end
    end
  end
end
