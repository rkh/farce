# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Fallback for Ruby implementations not supporting Ractor at all
    class Port
      def initialize = @queue = Thread::Queue.new
      def closed?    = @queue.closed?

      def close
        @queue.close
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
        self
      rescue ClosedQueueError
        raise Ractor::ClosedError, "The port was already closed"
      end

      alias << send

      def inspect = "#<#{self.class.name} to:#1 id:#{object_id}>"
    end

    BasePort = Port
  end
end
