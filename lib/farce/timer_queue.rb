# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A shareable timer queue with transfer modes for unshareable values.
  class TimerQueue < Abstract::TimerQueue
    include Internal::ManagedQueue
    include Shareable

    # (see Farce::Abstract::TimerQueue#initialize)
    # @!macro modes
    # @param mode [Symbol] the transfer mode for unshareable values
    def initialize(capacity: nil, mode: :copy, track_age: false)
      @manager = ModeManager.new(mode:)
      super(capacity:, track_age:)
    end

    # (see Farce::Abstract::TimerQueue#push)
    # @!macro modes
    # @param mode [Symbol] the transfer mode for unshareable values
    def push(value, non_block = false, mode: nil, timeout: nil, **time_options) # rubocop:disable Style/OptionalBooleanParameter
      at = Clock.parse(time_options)
      push_to_storage(at, non_block, @manager.wrap(value, mode:), timeout:)
    end

    # (see Farce::Abstract::TimerQueue#try_push)
    # @!macro modes
    # @param mode [Symbol] the transfer mode for unshareable values
    def try_push(value, mode: nil, **time_options)
      at = Clock.parse(time_options)
      return true if @queue.push(at, @manager.wrap(value, mode:))
      block_given? ? yield : false
    end

    # (see Farce::Abstract::TimerQueue#pop)
    def pop(non_block = false, timeout: nil) # rubocop:disable Style/OptionalBooleanParameter
      return try_pop { raise ThreadError, "queue empty" } if non_block
      deadline = timeout_at(timeout) unless timeout.nil?

      while true
        empty = false
        value = @queue.pop_before(Clock.now) { empty = true }
        return @manager.unwrap(value) unless empty
        return block_given? ? yield : nil if UNDEFINED.equal?(wait_for_timestamp(deadline))
      end
    end

    # (see Farce::Abstract::TimerQueue#try_pop)
    def try_pop
      empty = false
      value = @queue.pop_before(Clock.now) { empty = true }
      return @manager.unwrap(value) unless empty
      yield if block_given?
    end

    # (see Farce::Abstract::TimerQueue#peek)
    # @note Peeking at a moved value claims it for this Ractor while leaving it queued.
    def peek
      empty = false
      value = @queue.peek { empty = true }
      return @manager.unwrap(value) unless empty
      yield if block_given?
    end
  end
end
