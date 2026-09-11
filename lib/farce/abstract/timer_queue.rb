# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract Shared timer scheduling and blocking behavior.
    class TimerQueue < Queue
      include Internal::BlockingPriorityQueue

      # @param capacity [Integer, nil] the maximum number of values, or nil for an unbounded queue
      def initialize(capacity: nil, track_age: false)
        super
      end

      # Add a value to become available at the given time.
      # @param value [BasicObject] the value to add
      # @param non_block [Boolean] whether to raise an exception when the queue is at capacity
      # @param timeout [Numeric, nil] maximum number of seconds to wait for capacity
      # @param time_options [Hash{Symbol => Object}] a scheduling option accepted by {Clock.parse}:
      #   `at:`, `time:`, `timeout_at:`, `delay:`, `in:`, `offset:`, `wait:`, or `clock:`.
      #   With no scheduling option, the value is available immediately. Since `timeout:` controls the capacity wait,
      #   use `delay:` or `wait:` to schedule a relative offset.
      # @raise [ThreadError] when the queue is at capacity and non_block is true
      # @return [Boolean] whether the value was added
      def push(value, non_block = false, timeout: nil, **time_options) # rubocop:disable Style/OptionalBooleanParameter
        at = Clock.parse(time_options)
        push_to_storage(at, non_block, value, timeout:)
      end

      # Remove the earliest value, waiting until its timestamp is reached.
      # @param timeout [Numeric, nil] maximum number of seconds to wait
      # @yield called when the timeout expires first
      # @return [BasicObject, nil] the value or the fallback result
      def pop(non_block = false, timeout: nil) # rubocop:disable Style/OptionalBooleanParameter
        return try_pop { raise ThreadError, "queue empty" } if non_block
        deadline = timeout_at(timeout) unless timeout.nil?

        while true
          empty = false
          value = @queue.pop_before(Clock.now) { empty = true }
          return value unless empty
          return block_given? ? yield : nil if UNDEFINED.equal?(wait_for_timestamp(deadline))
        end
      end

      # Try to add a value without waiting for capacity.
      # @param value [BasicObject] the value to add
      # @param time_options [Hash{Symbol => Object}] a scheduling option accepted by {Clock.parse}:
      #   `at:`, `time:`, `timeout_at:`, `delay:`, `in:`, `offset:`, `timeout:`, `wait:`, or `clock:`.
      #   With no scheduling option, the value is available immediately.
      # @yield called when the queue is at capacity
      # @return [Boolean, BasicObject] true, or the fallback result when full
      def try_push(value, **time_options)
        at = Clock.parse(time_options)
        return true if @queue.push(at, value)
        block_given? ? yield : false
      end

      # Try to remove the earliest value only if its timestamp has been reached.
      # @yield called when no value is ready
      # @return [BasicObject, nil] the value or the fallback result
      def try_pop(&) = @queue.pop_before(Clock.now, &)

      # Return the earliest value without removing it, whether or not it is due.
      # @yield called when the queue is empty
      # @return [BasicObject, nil] the value or the fallback result
      def peek(&) = @queue.peek(&)

      # Return the earliest timestamp without removing it.
      # @yield called when the queue is empty
      # @return [Float, nil] the timestamp or the fallback result
      def first_timestamp(&) = @queue.peek_priority(&)

      # Return the latest timestamp without removing it.
      # @yield called when the queue is empty
      # @return [Float, nil] the timestamp or the fallback result
      def last_timestamp(&) = @queue.peek_last_priority(&)

      # Checks whether the earliest timestamp has been reached.
      # @param leeway [Numeric] how much leeway to allow for clock drift and scheduling delays
      def overdue?(leeway: 0)
        return false unless timestamp = first_timestamp
        timestamp <= Clock.in(leeway)
      end

      # Returns how long the earliest timestamp has been overdue, or nil if it is not yet due.
      # @param leeway [Numeric] how much leeway to allow for clock drift and scheduling delays
      # @return [Float, nil] the number of seconds overdue, or nil if the earliest timestamp is not yet due
      def overdue_by(leeway: 0)
        return unless timestamp = first_timestamp
        delay = Clock.now - timestamp
        delay > leeway ? delay : nil
      end

      # Wait until the earliest timestamp is reached without removing its value.
      # @param timeout [Numeric, nil] maximum number of seconds to wait
      # @return [Boolean] whether a value is ready
      def wait_pop(timeout: nil) # rubocop:disable Naming/PredicateMethod
        !UNDEFINED.equal?(wait_for_timestamp(timeout_at(timeout)))
      end

      # Delete the oldest matching value at the exact time.
      # @param value [BasicObject] the value to delete
      # @param at [Numeric, Time] the exact time to search
      # @param compare_by_identity [Boolean] compare values by identity instead of equality
      # @return [Boolean] whether a value was deleted
      def delete(value, at:, compare_by_identity: false)
        delete_from_storage(Clock.at(at), value, compare_by_identity:)
      end

      private

      def wait_for_timestamp(deadline)
        while true
          generation = @signal.generation
          timestamp = @queue.peek_priority
          wake_after = nil
          if timestamp
            delay = timestamp - Clock.now
            return timestamp unless delay.positive?
            wake_after = delay if delay.finite?
          end

          remaining = remaining_timeout(deadline)

          wait_for = wake_after && remaining ?
            (wake_after < remaining ? wake_after : remaining) :
            wake_after || remaining
          changed = @signal.wait(generation, timeout: wait_for)
          return UNDEFINED if !changed && deadline && remaining_timeout(deadline).zero?
        end
      end
    end
  end
end
