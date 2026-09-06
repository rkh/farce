# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Queue
      NIL_VALUE = Object.new.freeze
      attr_reader :capacity

      def initialize(capacity: 1024)
        @queue    = capacity ? Thread::SizedQueue.new(capacity) : Thread::Queue.new
        @capacity = capacity
        @signal   = Signal.new
        freeze
      end

      def pop(timeout: nil)
        timeout_at = timeout_at(timeout)
        # Observing an empty queue is sufficient for a nonblocking miss. Avoid
        # constructing a ThreadError (and its backtrace) just to return nil.
        if timeout_at&.zero? && @queue.empty?
          raise ClosedQueueError, "queue closed" if closed?
          return block_given? ? yield : nil
        end

        while true
          begin
            result = @queue.pop(true)
            broadcast
            return NIL_VALUE.equal?(result) ? nil : result
          rescue ThreadError
            remaining = remaining_timeout(timeout_at)
            return block_given? ? yield : nil unless wait_pop(timeout: remaining)
          end
        end
      end

      def push(item, timeout: nil)
        check_value(item)
        item = NIL_VALUE if item.nil?

        unless capacity
          @queue.push(item)
          broadcast
          return true
        end

        timeout_at = timeout_at(timeout)
        if timeout_at&.zero? && @queue.size >= @queue.max
          raise ClosedQueueError, "queue closed" if closed?
          return false
        end
        while true
          begin
            @queue.push(item, true)
            broadcast
            return true
          rescue ThreadError
            return false unless wait_push(timeout: remaining_timeout(timeout_at))
          end
        end
      end

      def wait_pop(timeout: nil) = wait(timeout) { size.positive? }

      def try_pop(&) = pop(timeout: 0, &)

      def try_push(item) = push(item, timeout: 0)

      def wait_push(timeout: nil)
        raise ClosedQueueError, "queue closed" if closed?
        return true unless capacity
        wait(timeout) { size < capacity }
      end

      def close
        @queue.close
        broadcast
        self
      end

      def clear
        @queue.clear
        broadcast
        self
      end

      def num_waiting = @queue.num_waiting + @signal.num_waiting

      Internal.delegate(self, :@queue, :closed?, :size)

      private

      def check_value(item)
        raise Ractor::IsolationError, "value is not Ractor-shareable" unless Ractor.shareable?(item)
      end

      def normalize_timeout(timeout)
        return nil if timeout.nil?
        timeout = Float(timeout)
        raise ArgumentError, "timeout must be non-negative" if timeout.negative?
        raise ArgumentError, "timeout must be finite" unless timeout.finite?
        raise ArgumentError, "timeout must be a number" if timeout.nan?
        timeout
      end

      def wait(timeout)
        timeout_at = timeout_at(timeout)

        if timeout_at&.zero?
          return true if yield
          raise ClosedQueueError, "queue closed" if closed?
          return false
        end

        while true
          generation = @signal.generation
          return true if yield
          raise ClosedQueueError, "queue closed" if closed?
          return false unless @signal.wait(generation, timeout: remaining_timeout(timeout_at))
        end
      end

      def timeout_at(timeout)
        return if timeout.nil?
        timeout = normalize_timeout(timeout)
        timeout.zero? ? 0 : Clock.timeout(timeout)
      end

      def remaining_timeout(timeout_at)
        return unless timeout_at
        return 0 if timeout_at.zero?
        timeout = timeout_at - Clock.now
        timeout.positive? ? timeout : 0
      end

      def broadcast = @signal.broadcast
    end
  end
end
