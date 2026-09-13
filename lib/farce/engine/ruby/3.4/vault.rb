# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/ruby/shared/vault"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Vault
      class Manager
        private def receive_request
          message = ::Ractor.receive
          return message if message.first.is_a?(Symbol)

          ticket, action, arguments = message
          [action, *arguments, ticket]
        end

        private def respond(port, message, move: false)
          return port.store(::Ractor.make_shareable(message)) if port.is_a?(Atom)
          ::Ractor.yield([port, message].freeze, move:)
        end
      end

      def initialize
        @lock     = Lock.new
        @sequence = Counter.new
        @ractor   = ::Ractor.new { Manager.new.run }
        ::Ractor.make_shareable(self)
      end

      private

      def execute(action, key, value = nil, move: false)
        raise Ractor::IsolationError, "key must be shareable" unless ::Ractor.shareable?(key)
        raise ThreadError, "deadlock; recursive access from the Vault Ractor" if ::Ractor.current.equal?(@ractor)
        ticket = @sequence.add
        @lock.synchronize do
          # Short nested arrays avoid the 3.4 move bug affecting later array elements.
          @ractor.send([ticket, action, [key, value].freeze].freeze, move:)
          loop do
            reply_ticket, response = @ractor.take
            # A canceled request can leave an older reply in the outgoing queue.
            next unless reply_ticket == ticket

            success, payload = response
            return success ? payload : raise(payload)
          end
        end
      end
    end
  end
end
