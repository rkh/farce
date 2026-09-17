# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Coordinates lazy Lease construction without running user code under a storage lock.
    class LeaseInitialization
      def initialize
        @mutex        = Mutex.new
        @signal       = Signal.new
        @lease        = nil
        @initializing = false
        @owner_fiber  = nil
        @owner_thread = nil
      end

      def fetch(timeout: nil, wait: true, &initializer)
        raise LocalJumpError, "no block given" unless initializer
        deadline = timeout_deadline(timeout)

        loop do
          initializing_here = false
          observed = @signal.generation
          begin
            Thread.handle_interrupt(INTERRUPT_MASK) { initializing_here = reserve }
            return @lease unless @lease.nil?
            return initialize_lease(&initializer) if initializing_here

            reject_recursive_initialization!
            return unless wait

            remaining = deadline - Clock.now if deadline
            return if remaining && !remaining.positive?
            reject_unscheduled_fiber_wait!
            @signal.wait(observed, timeout: wait_interval(remaining))
          ensure
            cancel_reservation if initializing_here
          end
        end
      end

      private

      def reserve
        @mutex.synchronize do
          return false if @lease || @initializing

          @initializing = true
          @owner_fiber = Fiber.current
          @owner_thread = Thread.current
          true
        end
      end

      def initialize_lease(&initializer)
        lease = initializer.call
        Thread.handle_interrupt(INTERRUPT_MASK) do
          @mutex.synchronize do
            @lease = lease
            clear_reservation
          end
          @signal.broadcast
        end
        lease
      end

      def cancel_reservation
        Thread.handle_interrupt(INTERRUPT_MASK) do
          canceled = @mutex.synchronize do
            next false unless @initializing && @owner_fiber.equal?(Fiber.current)

            clear_reservation
            true
          end
          @signal.broadcast if canceled
        end
      end

      def clear_reservation
        @initializing = false
        @owner_fiber = nil
        @owner_thread = nil
      end

      def reject_unscheduled_fiber_wait!
        return unless @owner_thread.equal?(Thread.current)
        return if Fiber.respond_to?(:scheduler) && Fiber.scheduler

        raise ThreadError, "deadlock; lease is initialized by another unscheduled Fiber on the same thread"
      end

      def reject_recursive_initialization!
        return unless @owner_fiber.equal?(Fiber.current)

        raise ThreadError, "deadlock; recursive lease initialization"
      end

      def timeout_deadline(timeout)
        return if timeout.nil?

        timeout = Float(timeout)
        unless timeout.finite? && !timeout.negative?
          raise ArgumentError, "timeout must be a finite, non-negative number or nil"
        end
        Clock.now + timeout
      end

      def wait_interval(remaining)
        LeaseWaiting.wait_interval(remaining)
      end
    end
  end
end
