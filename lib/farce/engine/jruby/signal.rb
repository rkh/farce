# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "java"
require "farce/engine/jvm/extension"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Signal < JVMExtension::QueueSignal
      NANOSECONDS        = java.util.concurrent.TimeUnit::NANOSECONDS
      READABLE           = IO::READABLE
      private_constant :NANOSECONDS, :READABLE

      def initialize
        super
        @fiber_waiters  = java.util.concurrent.ConcurrentHashMap.new
        @thread_waiters = java.util.concurrent.atomic.AtomicInteger.new
        Freeze.publish(self)
      end

      # JRuby-dev 10.1.2 cannot construct a Java subclass after a module is included.
      # Keep these methods local until its reifier is fixed.
      def freeze  = raise(TypeError, "#{self.class} cannot be frozen")
      def frozen? = false

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

        deadline = Clock.now + timeout if timeout
        registered = false
        begin
          Thread.handle_interrupt(INTERRUPT_MASK) do
            @thread_waiters.increment_and_get
            registered = true
          end
          loop do
            current = generation
            return current unless current == observed

            remaining = deadline - Clock.now if deadline
            return yield if remaining && !remaining.positive?

            # Java Phaser waits do not deliver Ruby cancellation until they return.
            # Retry bounded slices without shortening the caller's deadline.
            interval = LeaseWaiting.wait_interval(remaining)
            begin
              return await_advance_interruptibly(observed, (interval * 1_000_000_000).ceil, NANOSECONDS)
            rescue Java::JavaUtilConcurrent::TimeoutException
              # A positive Ruby sleep delivers :on_blocking interrupts too.
              # JRuby optimizes sleep(0) without entering a blocking region.
              sleep 0.000001
            end
          end
        ensure
          Thread.handle_interrupt(INTERRUPT_MASK) do
            @thread_waiters.decrement_and_get if registered
          end
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
