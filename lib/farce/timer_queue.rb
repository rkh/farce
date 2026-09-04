# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A priority queue whose priorities are absolute monotonic clock times.
  # Popping waits until the earliest entry is due. Changes wake waiters so a
  # newly inserted earlier entry immediately replaces their previous deadline.
  # Transfer modes apply only to values, which are automatically unwrapped by {#pop}, {#try_pop}, and {#peek}.
  # Timestamps are always normalized by {Clock.at}.
  class TimerQueue < Abstract::Queue
    include Internal::BlockingPriorityQueue
    include Shareable

    DeleteProbe = Data.define(:value, :compare_by_identity, :manager)
    Entry       = Data.define(:at, :value) do
      # @api private
      def ==(other)
        return super unless DeleteProbe === other
        other.manager.same_value?(value, other.value, identity: other.compare_by_identity)
      end
    end

    private_constant :DeleteProbe, :Entry

    # @!macro modes
    # @param capacity [Integer, nil] the maximum number of values, or nil for an unbounded queue
    # @param mode [Symbol] the default mode used to transfer values between Ractors
    def initialize(capacity: nil, mode: :copy)
      @manager = ModeManager.new(mode:)
      super(capacity:)
    end

    # Add a value to become available at the given time.
    # @!macro modes
    # @param value [BasicObject] the value to add
    # @param non_block [Boolean] whether to raise an exception when the queue is at capacity
    # @param at [Numeric, Time] an absolute time accepted by Clock.at
    # @param timeout [Numeric, nil] maximum number of seconds to wait for capacity
    # @param mode [Symbol, nil] the transfer mode, or nil to use the queue's default mode
    # @raise [ThreadError] when the queue is at capacity and non_block is true
    # @return [Boolean] whether the value was added
    def push(value, non_block = false, at: Clock.now, timeout: nil, mode: nil) # rubocop:disable Style/OptionalBooleanParameter
      at    = normalize_at(at)
      entry = Entry.new(at, @manager.wrap(value, mode:))
      push_to_storage(at, non_block, entry, timeout:)
    end

    # Remove the earliest value, waiting until its timestamp is reached.
    # @param timeout [Numeric, nil] maximum number of seconds to wait
    # @yield called when the timeout expires first
    # @return [BasicObject, nil] the value or the fallback result
    def pop(non_block = false, timeout: nil) # rubocop:disable Style/OptionalBooleanParameter
      return try_pop { raise ThreadError, "queue empty" } if non_block
      deadline = timeout_at(timeout)

      while true
        entry = wait_for_entry(deadline)
        return block_given? ? yield : nil if UNDEFINED.equal?(entry)
        return @manager.unwrap(entry.value) if @queue.delete_identity(entry.at, entry)
      end
    end

    # Try to add a value without waiting for capacity.
    # @!macro modes
    # @param value [BasicObject] the value to add
    # @param at [Numeric, Time] an absolute time accepted by Clock.at
    # @param mode [Symbol, nil] the transfer mode, or nil to use the queue's default mode
    # @yield called when the queue is at capacity
    # @return [Boolean, BasicObject] true, or the fallback result when full
    def try_push(value, at: Clock.now, mode: nil)
      at    = normalize_at(at)
      entry = Entry.new(at, @manager.wrap(value, mode:))
      return true if @queue.push(at, entry)
      block_given? ? yield : false
    end

    # Try to remove the earliest value only if its timestamp has been reached.
    # @yield called when no value is ready
    # @return [BasicObject, nil] the value or the fallback result
    def try_pop
      until UNDEFINED.equal?(entry = @queue.peek { UNDEFINED })
        break if entry.at > Clock.now
        return @manager.unwrap(entry.value) if @queue.delete_identity(entry.at, entry)
      end
      yield if block_given?
    end

    # Return the earliest value without removing it, whether or not it is due.
    # @note Peeking at a value stored with `:move` claims it for the current Ractor even though it remains queued.
    # @yield called when the queue is empty
    # @return [BasicObject, nil] the value or the fallback result
    def peek
      entry = @queue.peek { UNDEFINED }
      return @manager.unwrap(entry.value) unless UNDEFINED.equal?(entry)
      yield if block_given?
    end

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
      !UNDEFINED.equal?(wait_for_entry(timeout_at(timeout)))
    end

    # Delete the oldest matching value at the exact time.
    # @param value [BasicObject] the value to delete
    # @param at [Numeric, Time] the exact time to search
    # @param compare_by_identity [Boolean] compare values by identity instead of equality
    # @raise [Ractor::IsolationError] when an unshareable equality comparison value cannot be copied
    # @return [Boolean] whether a value was deleted
    def delete(value, at:, compare_by_identity: false)
      comparison_mode = compare_by_identity ? :local : :copy
      value = @manager.wrap(value, mode: comparison_mode)
      probe = DeleteProbe.new(value, compare_by_identity, @manager)
      @queue.delete(normalize_at(at), probe)
    end

    private

    def normalize_at(at)
      at = Clock.at(at)
      raise ArgumentError, "timestamp must not be NaN" if at.nan?

      at
    end

    def wait_for_entry(deadline)
      while true
        generation = @signal.generation
        raise ClosedQueueError, "queue closed" if closed?

        entry = @queue.peek { UNDEFINED }
        unless UNDEFINED.equal?(entry)
          delay = entry.at - Clock.now
          return entry unless delay.positive?
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
