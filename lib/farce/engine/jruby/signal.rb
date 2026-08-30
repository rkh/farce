# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "java"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Signal < java.util.concurrent.Phaser
      MAXIMUM_GENERATION = (2**31) - 1
      MAXIMUM_TIMEOUT    = (2**63) - 1
      NANOSECONDS        = java.util.concurrent.TimeUnit::NANOSECONDS
      READABLE           = IO::READABLE
      private_constant :MAXIMUM_GENERATION, :MAXIMUM_TIMEOUT, :NANOSECONDS, :READABLE

      def initialize
        super(1)
        @broadcast_lock = Mutex.new
        @fiber_waiters  = java.util.concurrent.ConcurrentHashMap.new
        freeze
      end

      def generation = phase

      def broadcast
        generation = @broadcast_lock.synchronize do
          previous = arrive
          previous == MAXIMUM_GENERATION ? 0 : previous + 1
        end
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
      end

      def wait_with_scheduler(scheduler, observed, timeout)
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
        @fiber_waiters.delete(writer) if writer
        reader&.close
        writer&.close
      end
    end
  end
end
