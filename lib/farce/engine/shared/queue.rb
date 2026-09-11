# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Queue
      NIL_VALUE = Object.new.freeze
      attr_reader :capacity

      def initialize(capacity: 1024, track_age: false)
        @queue    = capacity ? Thread::SizedQueue.new(capacity) : Thread::Queue.new
        @capacity = capacity
        @signal   = Signal.new
        @tracking = track_age ? { lock: Mutex.new, timestamps: [], generation: 0 } : nil
        @lifecycle = { lock: Mutex.new, hard_closed: false }
        freeze
      end

      def pop(timeout: nil)
        timeout_at = timeout_at(timeout)
        # Observing an empty queue is sufficient for a nonblocking miss. Avoid
        # constructing a ThreadError (and its backtrace) just to return nil.
        if timeout_at&.zero? && @queue.empty?
          raise_closed if closed?
          return block_given? ? yield : nil
        end

        while true
          begin
            result = tracked_pop
            raise ThreadError if result.nil? && @queue.closed?
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
          tracked_push(item)
          broadcast
          return true
        end

        timeout_at = timeout_at(timeout)
        if timeout_at&.zero? && @queue.size >= @queue.max
          raise_unwritable if sealed?
          return false
        end
        while true
          begin
            tracked_push(item, non_block: true)
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
        raise_unwritable if sealed?
        return true unless capacity
        wait(timeout) do
          raise_unwritable if sealed?
          size < capacity
        end
      end

      def close
        @lifecycle[:lock].synchronize do
          changed = !@lifecycle[:hard_closed]
          @lifecycle[:hard_closed] = true
          @queue.close
          bump_generation if changed
        end
        broadcast
        self
      end

      def seal
        @lifecycle[:lock].synchronize do
          changed = !@queue.closed?
          @queue.close
          bump_generation if changed
        end
        broadcast
        self
      end

      def clear
        if @tracking
          @tracking[:lock].synchronize do
            changed = @queue.size.positive?
            @queue.clear
            @tracking[:timestamps].clear
            @tracking[:generation] += 1 if changed
          end
        else
          @queue.clear
        end
        broadcast
        self
      end

      def num_waiting = @queue.num_waiting + @signal.num_waiting

      Internal.delegate(self, :@queue, :size)

      def sealed? = @queue.closed?

      def closed?
        @lifecycle[:hard_closed] || (@queue.closed? && @queue.empty?)
      end

      def age_tracking? = !@tracking.nil?
      def generation = @tracking && @tracking[:lock].synchronize { @tracking[:generation] }

      def oldest_enqueued_at
        @tracking && @tracking[:lock].synchronize { @tracking[:timestamps].first }
      end

      def oldest_age
        timestamp = oldest_enqueued_at
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - timestamp if timestamp
      end

      private

      def check_value(item)
        raise Ractor::IsolationError, "value is not Ractor-shareable" unless Ractor.shareable?(item)
      end

      def tracked_push(item, non_block: false)
        if @tracking
          @tracking[:lock].synchronize do
            result = @queue.push(item, non_block)
            @tracking[:timestamps] << Process.clock_gettime(Process::CLOCK_MONOTONIC)
            @tracking[:generation] += 1
            result
          end
        else
          @queue.push(item, non_block)
        end
      rescue ::ClosedQueueError
        raise_unwritable
      end

      def tracked_pop
        return @queue.pop(true) unless @tracking
        @tracking[:lock].synchronize do
          result = @queue.pop(true)
          unless result.nil? && @queue.closed?
            @tracking[:timestamps].shift
            @tracking[:generation] += 1
          end
          result
        end
      end

      def bump_generation
        @tracking[:lock].synchronize { @tracking[:generation] += 1 } if @tracking
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
          raise_closed if closed?
          return false
        end

        while true
          generation = @signal.generation
          return true if yield
          raise_closed if closed?
          return false unless @signal.wait(generation, timeout: remaining_timeout(timeout_at))
        end
      end

      def raise_closed
        raise ::Farce::Queue::ClosedError, "queue is closed"
      end

      def raise_unwritable
        closed = closed?
        error = closed ? ::Farce::Queue::ClosedError : ::Farce::Queue::SealedError
        raise error, closed ? "queue is closed" : "queue is sealed"
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
