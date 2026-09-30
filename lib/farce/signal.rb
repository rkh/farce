# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A Ractor-shareable notification signal for changes to separately synchronized state.
  # Broadcast after updating the state. Waiters check that state again after each notification.
  # A broadcast wakes all current waiters and advances the signal's generation.
  #
  # @example Waiting for a resource
  #   signal    = Farce::Signal.new
  #   resources = Farce::Strict::Queue.new
  #   producer  = Thread.new do
  #     resources.push(:resource)
  #     signal.broadcast
  #   end
  #   resource = signal.wait_until(timeout: 1.0) { resources.try_pop }
  #   producer.join
  #   resource # => :resource, or nil if the timeout expires
  #
  class Signal
    include Internal::Noncopyable
    include Shareable::Unfreezable

    def initialize
      @signal = Internal::Signal.new
      super
    end

    # Read the current generation. Take this snapshot before checking external state.
    # @return [Integer] the current generation, initially zero
    def generation = @signal.generation

    # Advance the generation and wake all current waiters.
    # @return [Integer] the new generation
    def broadcast = @signal.broadcast

    # @return [Integer] the number of callers currently waiting
    def num_waiting = @signal.num_waiting

    # Wait for the generation to change. Without a snapshot, wait for the next broadcast.
    # Return immediately if the supplied generation has already changed.
    # @param observed [Integer, nil] a generation snapshot, or nil to take a snapshot now
    # @param timeout [Numeric, nil] the maximum seconds to wait, or nil to wait indefinitely
    # @yield called without arguments when the timeout expires
    # @return [Integer, BasicObject, nil] the changed generation, or the fallback result or nil on timeout
    def wait(observed = nil, timeout: nil, &) = @signal.wait(observed, timeout:, &)

    # Check a condition immediately, then after broadcasts while it remains truthy.
    # Uses the same timeout budget and notification handling as {#wait_until}.
    # @param timeout [Numeric, nil] the total seconds available, or nil to wait indefinitely
    # @yield checks the condition
    # @yieldreturn [BasicObject] a truthy value to keep waiting, or nil or false to stop
    # @return [true, nil] true when the condition becomes false, or nil on timeout
    # @raise [LocalJumpError] if no block is given
    def wait_while(timeout: nil)
      raise LocalJumpError, "no block given" unless block_given?
      wait_until(timeout:) { !yield }
    end

    # Check a condition immediately, then check again after broadcasts until it succeeds.
    # Take a generation snapshot before every check so a broadcast during the check is not missed.
    # The block runs in the caller without holding a signal lock. Synchronize access to shared state
    # inside the block, and claim the resource there if another waiter could consume it.
    #
    # One timeout budget covers all checks and waits. The block is not interrupted when time expires.
    # A timeout of zero checks once without waiting. Exceptions from the block propagate to the caller.
    #
    # @param timeout [Numeric, nil] the total seconds available, or nil to wait indefinitely
    # @yield checks or claims the resource
    # @yieldreturn [BasicObject, nil, false] a truthy result on success, or nil or false to keep waiting
    # @return [BasicObject, nil] the first truthy block result, or nil on timeout
    # @raise [LocalJumpError] if no block is given
    # @raise [ArgumentError] if the timeout is negative or not finite
    def wait_until(timeout: nil)
      raise LocalJumpError, "no block given" unless block_given?
      Internal.with_timeout(timeout) do |_, deadline|
        observed = generation
        result   = yield
        return result if result

        remaining = deadline - Clock.now if deadline
        return if remaining && !remaining.positive?
        return unless wait(observed, timeout: remaining)
      end
    end
  end
end
