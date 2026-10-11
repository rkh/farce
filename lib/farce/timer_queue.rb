# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A shareable timer queue with transfer modes for unshareable values.
  class TimerQueue < Farce::Abstract::TimerQueue
    include Internal::ManagedQueue
    include Shareable::Unfreezable

    # (see Farce::Abstract::TimerQueue#initialize)
    # @!macro modes
    # @param mode [Symbol] the transfer mode for unshareable values
    def initialize(capacity: nil, mode: :smart, track_age: false)
      @manager = ModeManager.new(mode:)
      super(capacity:, track_age:)
    end

    # (see Farce::Abstract::TimerQueue#push)
    # @!macro modes
    # @param mode [Symbol] the transfer mode for unshareable values
    def push(value, non_block = false, mode: nil, timeout: nil, **time_options) # rubocop:disable Style/OptionalBooleanParameter
      at    = Clock.parse(time_options)
      value = @manager.wrap(value, mode:)
      entry = Entry.new(value, at, self)
      push_to_storage(at, non_block, value, timeout:) && entry
    end

    # (see Farce::Abstract::TimerQueue#try_push)
    # @!macro modes
    # @param mode [Symbol] the transfer mode for unshareable values
    def try_push(value, mode: nil, **time_options)
      at    = Clock.parse(time_options)
      value = @manager.wrap(value, mode:)
      entry = Entry.new(value, at, self)
      return entry if @queue.push(at, value)
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

    private

    def delete_from_storage(priority, value, compare_by_identity:)
      if compare_by_identity && @manager.managed_envelope?(value)
        @queue.delete_identity(priority, value)
      else
        super
      end
    end
  end
end
