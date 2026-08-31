# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Exchanger
      TIMED_OUT = Object.new.freeze
      WAITING   = Object.new.freeze
      Waiter = Struct.new(:condition, :matched, :offered, :reader, :received, :scheduler, :writer)
      private_constant :TIMED_OUT, :WAITING, :Waiter

      def initialize
        @mutex   = Mutex.new
        @waiting = [nil]
        freeze
      end

      def exchange(offered, timeout: nil, &fallback)
        deadline = timeout_deadline(timeout)
        waiter   = build_waiter(offered)

        partner = @mutex.synchronize do
          if partner = @waiting.first
            @waiting[0] = nil
            partner.received = offered
            partner.matched  = true
            notify(partner)
            partner
          elsif deadline && deadline <= Clock.now
            TIMED_OUT
          else
            @waiting[0] = waiter
            nil
          end
        end

        return partner.offered if partner && !TIMED_OUT.equal?(partner)
        return timed_out(fallback) if TIMED_OUT.equal?(partner)

        result = waiter.scheduler ? wait_with_scheduler(waiter, deadline) : wait_with_condition(waiter, deadline)
        TIMED_OUT.equal?(result) ? timed_out(fallback) : result
      ensure
        remove(waiter) if waiter
        waiter&.reader&.close
        waiter&.writer&.close
      end

      private

      def build_waiter(offered)
        scheduler = Fiber.current_scheduler if Fiber.respond_to?(:current_scheduler)
        # JRuby may run a later scheduled fiber on a backing thread where this is nil.
        scheduler ||= Fiber.scheduler if Fiber.respond_to?(:scheduler) && !Fiber.current.blocking?
        reader, writer = IO.pipe if scheduler
        Waiter.new(
          condition: ConditionVariable.new,
          matched:   false,
          offered:   offered,
          reader:    reader,
          scheduler: scheduler,
          writer:    writer,
        )
      end

      def notify(waiter)
        if waiter.scheduler
          waiter.writer.write_nonblock(".", exception: false)
        else
          waiter.condition.broadcast
        end
      end

      def wait_with_condition(waiter, deadline)
        @mutex.synchronize do
          until waiter.matched
            remaining = deadline - Clock.now if deadline
            return cancel(waiter) if remaining && !remaining.positive?
            waiter.condition.wait(@mutex, remaining)
          end
          waiter.received
        end
      end

      def wait_with_scheduler(waiter, deadline)
        loop do
          state, result = @mutex.synchronize do
            if waiter.matched
              [nil, waiter.received]
            else
              remaining = deadline - Clock.now if deadline
              remaining && !remaining.positive? ? [nil, cancel(waiter)] : [WAITING, remaining]
            end
          end
          return result unless WAITING.equal?(state)

          waiter.scheduler.io_wait(waiter.reader, IO::READABLE, result)
        end
      end

      def cancel(waiter)
        remove(waiter)
        waiter.matched ? waiter.received : TIMED_OUT
      end

      def remove(waiter)
        @mutex.owned? ? remove_locked(waiter) : @mutex.synchronize { remove_locked(waiter) }
      end

      def remove_locked(waiter)
        @waiting[0] = nil if @waiting.first.equal?(waiter)
      end

      def timeout_deadline(timeout)
        return unless timeout

        timeout = Float(timeout)
        if !timeout.finite? || timeout.negative?
          raise ArgumentError, "timeout must be a finite, non-negative number or nil"
        end
        Clock.now + timeout
      end

      def timed_out(fallback) = fallback&.call
    end
  end
end
