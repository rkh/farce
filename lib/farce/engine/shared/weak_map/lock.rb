# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # A per-key reservation. User code runs without holding the state mutex.
    # The same lock protects creation in a key index, as in Storage::ThreadSafe.
    class UnsharedWeakMapLock
      def initialize
        @mutex = Mutex.new
        @reserved = false
        @owner_fiber = nil
        @owner_thread = nil
        @signal = nil
      end

      def reserve(deadline)
        while true
          signal, observed = @mutex.synchronize do
            return :retired if unavailable?
            unless @reserved
              @reserved = true
              @owner_fiber = Fiber.current
              @owner_thread = Internal.storage_thread(Thread.current)
              return :acquired
            end
            reject_recursive_wait!
            @signal ||= Signal.new
            [@signal, @signal.generation]
          end
          return :timed_out unless ReservationWaiting.wait(signal, observed, deadline)
        end
      end

      def release
        signal = @mutex.synchronize do
          @reserved    = false
          @owner_fiber = @owner_thread = nil
          @signal
        end
        signal&.broadcast
      end

      def synchronize(deadline = nil)
        acquired = reserve(deadline) == :acquired
        acquired ? [true, yield] : [false, nil]
      ensure
        release if acquired
      end

      def try_synchronize
        acquired = @mutex.synchronize do
          next false if @reserved
          @reserved     = true
          @owner_fiber  = Fiber.current
          @owner_thread = Internal.storage_thread(Thread.current)
          true
        end
        acquired ? [true, yield] : [false, nil]
      ensure
        release if acquired
      end

      private

      def unavailable? = false

      def reject_recursive_wait!
        raise ThreadError, "deadlock; recursive weak-map access during an update" if @owner_fiber.equal?(Fiber.current)
        scheduler = Fiber.scheduler if Fiber.respond_to?(:scheduler)
        return unless @owner_thread.equal?(Internal.storage_thread(Thread.current)) && !scheduler

        raise ThreadError, "deadlock; weak-map update is owned by another unscheduled fiber"
      end
    end
    private_constant :UnsharedWeakMapLock
  end
end
