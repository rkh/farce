# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A shareable FIFO queue with transfer modes for unshareable values.
  class Queue < Abstract::Queue
    # Raised when an operation cannot proceed because the queue is closed.
    class ClosedError < ::ClosedQueueError
    end

    # Raised when a push cannot proceed because the queue is sealed.
    class SealedError < ClosedError
    end

    include Internal::ManagedQueue
    include Shareable

    # @!macro modes
    def initialize(capacity: 1024, mode: :copy, track_age: false)
      @manager = ModeManager.new(mode:)
      @queue = Internal::Queue.new(capacity:, track_age:)
      super()
    end

    # @!macro modes
    def push(value, non_block = false, timeout: nil, mode: nil) # rubocop:disable Style/OptionalBooleanParameter
      value = @manager.wrap(value, mode:)

      if non_block
        return true if @queue.try_push(value)
        raise ThreadError, "queue full"
      end

      timeout.nil? ? @queue.push(value) : @queue.push(value, timeout:)
    end

    # @!macro modes
    def try_push(value, mode: nil)
      return true if @queue.try_push(@manager.wrap(value, mode:))
      block_given? ? yield : false
    end

    def pop(non_block = false, timeout: nil) # rubocop:disable Style/OptionalBooleanParameter
      return try_pop { raise ThreadError, "queue empty" } if non_block

      empty = false
      result = timeout.nil? ? @queue.pop { empty = true } : @queue.pop(timeout:) { empty = true }
      return @manager.unwrap(result) unless empty
      yield if block_given?
    end

    def try_pop
      empty = false
      result = @queue.try_pop { empty = true }
      return @manager.unwrap(result) unless empty
      yield if block_given?
    end
  end
end
