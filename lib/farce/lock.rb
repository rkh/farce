# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  if Internal.native_ractors?
    # A Ractor-shareable mutual-exclusion lock with the same interface as Ruby's Mutex.
    #
    # Lock ownership belongs to the current Fiber. Attempting to lock the same lock recursively raises
    # ThreadError. Waiting for a lock cooperates with an installed Fiber scheduler.
    #
    # @!method lock
    #   Acquire the lock, waiting until it is available.
    #   @return [self]
    #   @raise [ThreadError] if the current Fiber already owns the lock
    #
    # @!method locked?
    #   @return [Boolean] whether any Fiber owns the lock
    #
    # @!method owned?
    #   @return [Boolean] whether the current Fiber owns the lock
    #
    # @!method sleep(timeout = nil)
    #   Release the lock while sleeping, then reacquire it before returning.
    #   @param timeout [Numeric, nil] the maximum number of seconds to sleep, or nil to sleep indefinitely
    #   @return [nil]
    #   @raise [ThreadError] if the current Fiber does not own the lock
    #
    # @!method synchronize
    #   Acquire the lock for the duration of the block.
    #   @yield the block to run while holding the lock
    #   @return [Object] the block result
    #   @raise [ThreadError] if no block is given or the current Fiber already owns the lock
    #
    # @!method try_lock
    #   Attempt to acquire the lock without waiting.
    #   @return [Boolean] whether the lock was acquired
    #
    # @!method unlock
    #   Release the lock.
    #   @return [self]
    #   @raise [ThreadError] if the current Fiber does not own the lock
    class Lock < Internal::Lock
      include Shareable
    end
  else
    # JRuby and TruffleRuby have no native Ractors, so their native Mutex is sufficient.
    const_set(:Lock, Mutex)
  end
end
