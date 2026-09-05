# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "java"
require "farce/engine/jvm/extension"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Signal < JVMExtension::QueueSignal
      MAXIMUM_TIMEOUT    = (2**63) - 1
      NANOSECONDS        = java.util.concurrent.TimeUnit::NANOSECONDS
      READABLE           = IO::READABLE
      INTERRUPT_MASK     = { Exception => :never }.freeze
      private_constant :MAXIMUM_TIMEOUT, :NANOSECONDS, :READABLE, :INTERRUPT_MASK

      def initialize
        super
        @fiber_waiters  = java.util.concurrent.ConcurrentHashMap.new
        @thread_waiters = java.util.concurrent.atomic.AtomicInteger.new
        freeze
      end

      def generation = phase
      def num_waiting = @thread_waiters.get + @fiber_waiters.size

      def broadcast
        generation = broadcastThreads

        # Publish the generation even with no waiters, so a waiter registering
        # concurrently can detect the broadcast before it parks.
        return generation if @fiber_waiters.empty?

        @fiber_waiters.key_set.each do |writer|
          writer.write_nonblock(".", exception: false)
        rescue IOError, SystemCallError
          nil
        end
        generation
      end

      def wait(observed = nil, timeout: nil)
        validate_generation(observed) unless observed.nil?
        timeout = parse_timeout(timeout)
        observed ||= generation

        scheduler = Fiber.current_scheduler if Fiber.respond_to?(:current_scheduler)
        # JRuby may run a later scheduled fiber on a backing thread where this is nil.
        scheduler ||= Fiber.scheduler if !Fiber.current.blocking? && Fiber.respond_to?(:scheduler)
        return wait_with_scheduler(scheduler, observed, timeout) { yield if block_given? } if scheduler

        wait_with_phaser(observed, timeout) { yield if block_given? }
      end

      private

      def validate_generation(generation)
        raise TypeError, "generation must be an Integer" unless generation.is_a?(::Integer)
      end

      def parse_timeout(timeout)
        return unless timeout

        timeout = Float(timeout)
        if !timeout.finite? || timeout.negative?
          raise ArgumentError, "timeout must be a finite, non-negative number or nil"
        end
        timeout
      end

      def wait_with_phaser(observed, timeout)
        current = generation
        return current unless current == observed

        @thread_waiters.increment_and_get
        begin
          return await_advance(observed) unless timeout

          nanoseconds =
            if timeout >= MAXIMUM_TIMEOUT.fdiv(1_000_000_000)
              MAXIMUM_TIMEOUT
            else
              (timeout * 1_000_000_000).ceil
            end
          await_advance_interruptibly(observed, nanoseconds, NANOSECONDS)
        rescue Java::JavaUtilConcurrent::TimeoutException
          yield if block_given?
        ensure
          @thread_waiters.decrement_and_get
        end
      end

      def wait_with_scheduler(scheduler, observed, timeout)
        current = generation
        return current unless current == observed

        # The Java monitor closes the registration/commit race. Publish the
        # registration flag under an interrupt mask so cancellation cannot
        # leak a registration between the Java return and Ruby assignment.
        registered = false
        Thread.handle_interrupt(INTERRUPT_MASK) do
          beginSchedulerWait
          registered = true
        end
        deadline = Clock.now + timeout if timeout
        reader, writer = IO.pipe
        @fiber_waiters[writer] = true

        loop do
          current = generation
          return current unless current == observed

          remaining = deadline - Clock.now if deadline
          return yield if remaining && !remaining.positive?

          scheduler.io_wait(reader, READABLE, remaining)
        end
      ensure
        Thread.handle_interrupt(INTERRUPT_MASK) do
          @fiber_waiters.delete(writer) if writer
          reader&.close
          writer&.close
        ensure
          endSchedulerWait if registered
        end
      end
    end
  end
end
