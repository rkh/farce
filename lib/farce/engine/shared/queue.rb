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
        @signals  = Set.new.compare_by_identity
        @mutex    = Mutex.new
      end

      def pop(timeout: nil)
        result = @queue.pop(timeout:)
        return block_given? ? yield : nil if result.nil?
        broadcast
        result unless NIL_VALUE.equal?(result)
      end

      def push(item, timeout: nil) # rubocop:disable Naming/PredicateMethod
        item = NIL_VALUE if item.nil?

        if capacity
          return false unless @queue.push(item, timeout:)
        else
          @queue.push(item)
        end

        broadcast
        true
      end

      def wait_pop(timeout: nil) = wait(timeout) { size.positive? }

      def wait_push(timeout: nil)
        return true unless capacity
        wait(timeout) { size < capacity }
      end

      Internal.delegate(self, :@queue, :clear, :close, :size)

      private

      def wait(timeout)
        timeout_at = Clock.timeout(timeout) if timeout

        until yield
          return false if timeout_at && Clock.now >= timeout_at
          signal ||= register_signal
          mutex  ||= Mutex.new
          mutex.synchronize { signal.wait(mutex, timeout_at ? timeout_at - Clock.now : nil) }
        end

        true
      ensure
        unregister_signal(signal) if signal
      end

      def register_signal
        signal = ConditionVariable.new
        @mutex.synchronize { @signals.add(signal) }
        signal
      end

      def broadcast = @mutex.synchronize { @signals.each(&:broadcast) }
      def unregister_signal(signal) = @mutex.synchronize { @signals.delete(signal) }
    end
  end
end
