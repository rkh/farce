# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # A bounded, blocking minimum-priority queue. Equal priorities are popped in
    # insertion order. Each engine defines the storage primitives directly on
    # this class; this file adds the common blocking and timeout behavior. On
    # CRuby the instance is shareable between Ractors, and waits go through
    # Signal so a Fiber scheduler can park the current Fiber instead of its
    # thread.
    class PriorityQueue
      EMPTY_RESULT = Object.new.freeze
      private_constant :EMPTY_RESULT

      def initialize(capacity: 1024)
        signal = Signal.new
        initialize_storage(capacity:, signal:)
      end

      def push(priority, value, timeout: nil)
        timeout_at = timeout_at(timeout)

        while true # rubocop:disable Style/InfiniteLoop
          return true if try_push(priority, value)
          return false unless wait_push(timeout: remaining_timeout(timeout_at))
        end
      end

      def pop(timeout: nil)
        timeout_at = timeout_at(timeout)

        while true # rubocop:disable Style/InfiniteLoop
          result = try_pop { EMPTY_RESULT }
          return result unless EMPTY_RESULT.equal?(result)

          remaining = remaining_timeout(timeout_at)
          return block_given? ? yield : nil unless wait_pop(timeout: remaining)
        end
      end

      def wait_pop(timeout: nil) = wait(timeout) { size.positive? }

      def wait_push(timeout: nil)
        raise ClosedQueueError, "queue closed" if closed?
        return true unless capacity
        wait(timeout) { size < capacity }
      end

      private

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

        while true # rubocop:disable Style/InfiniteLoop
          generation = @signal.generation
          raise ClosedQueueError, "queue closed" if closed?
          return true if yield
          return false unless @signal.wait(generation, timeout: remaining_timeout(timeout_at))
        end
      end

      def timeout_at(timeout)
        Clock.timeout(normalize_timeout(timeout)) unless timeout.nil?
      end

      def remaining_timeout(timeout_at)
        return unless timeout_at
        [timeout_at - Clock.now, 0].max
      end

      private :initialize_storage, :try_push, :try_pop
    end
  end
end
