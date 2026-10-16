# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Fallback for Ruby implementations not supporting Ractor at all
    class Port
      include MarshalSupport::Reject
      include Freeze::Unfreezable

      def initialize
        @queue          = Thread::Queue.new
        @select_mutex   = Mutex.new
        @select_waiters = []
      end

      def closed? = @queue.closed?

      def close
        @select_mutex.synchronize do
          @queue.close
          @select_waiters.each { it << true }
        end
        self
      end

      def receive(timeout: nil)
        raise Ractor::ClosedError, "The port was already closed" if closed?
        @queue.pop(timeout:)
      end

      def send(value, move: false)
        if value.is_a?(Unshareable)
          raise TypeError, "cannot share #{value.class} object between Ractors" unless move
          raise Ractor::Error, "can not move #{value.class} object" unless value.is_a?(Unshareable::Movable)
        end
        @queue.push(value)
        notify_selectors
        self
      rescue ::ClosedQueueError
        raise Ractor::ClosedError, "The port was already closed"
      end

      # @api private
      def register_selector(waiter)
        @select_mutex.synchronize { @select_waiters << waiter }
      end

      # @api private
      def unregister_selector(waiter)
        @select_mutex.synchronize { @select_waiters.delete(waiter) }
      end

      # @api private
      def select_receive
        @select_mutex.synchronize do
          raise Ractor::ClosedError, "The port was already closed" if closed?
          begin
            value = @queue.pop(true)
          rescue ThreadError
            return
          end
          [self, value]
        end
      end

      alias << send

      def inspect = "#<#{self.class.name} to:#1 id:#{object_id}>"

      private

      def notify_selectors
        @select_mutex.synchronize { @select_waiters.each { it << true } }
      end
    end

    BasePort = Port
  end
end
