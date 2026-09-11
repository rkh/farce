# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A shareable priority queue with transfer modes for unshareable values.
  class PriorityQueue < Abstract::PriorityQueue
    include Internal::ManagedQueue
    include Shareable

    # @!macro modes
    def initialize(capacity: nil, default_priority: 0, order: :ascending, mode: :copy, track_age: false)
      @manager = ModeManager.new(mode:)
      super(capacity:, default_priority:, order:, track_age:)
    end

    # @!macro modes
    def push(value, non_block = false, priority: default_priority, timeout: nil, mode: nil) # rubocop:disable Style/OptionalBooleanParameter
      push_to_storage(priority, non_block, @manager.wrap(value, mode:), timeout:)
    end

    # @!macro modes
    def try_push(value, priority: default_priority, mode: nil)
      return true if @queue.push(priority, @manager.wrap(value, mode:))

      block_given? ? yield : false
    end

    def pop(non_block = false, timeout: nil) # rubocop:disable Style/OptionalBooleanParameter
      return try_pop { raise ThreadError, "queue empty" } if non_block
      deadline = timeout_at(timeout) unless timeout.nil?

      while true
        empty  = false
        result = @reverse_order ? @queue.pop_last { empty = true } : @queue.pop { empty = true }

        return @manager.unwrap(result) unless empty
        remaining = remaining_timeout(deadline)
        return block_given? ? yield : nil unless wait_pop(timeout: remaining)
      end
    end

    def try_pop
      empty  = false
      result = @reverse_order ? @queue.pop_last { empty = true } : @queue.pop { empty = true }
      return @manager.unwrap(result) unless empty
      yield if block_given?
    end

    # Peeking at a moved value claims it for this Ractor while leaving it queued.
    def peek
      empty  = false
      result = if @reverse_order
                 @queue.peek_last { empty = true }
               else
                 @queue.peek { empty = true }
               end
      empty ? (block_given? ? yield : nil) : @manager.unwrap(result)
    end
  end
end
