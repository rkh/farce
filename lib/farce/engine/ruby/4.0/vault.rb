# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/ruby/shared/vault"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Vault
      if System.windows?
        # A Windows Port receiver can remain asleep after its reply was sent.
        # Wait for a native Atom notification before consuming the queued reply.
        class ReplyPort
          def initialize
            @port = ::Ractor::Port.new
            @ready = Atom.new
            ::Ractor.make_shareable(self)
          end

          def send(message, move: false)
            @port.send(message, move:)
            @ready.store(true)
          end

          def receive
            @ready.wait_until_non_nil
            @port.receive
          end

          def close = @port.close
          def closed? = @port.closed?
        end
      else
        ReplyPort = ::Ractor::Port
      end
      private_constant :ReplyPort

      class Manager
        private def receive_request = ::Ractor.receive

        private def respond(port, message, move: false)
          return port.store(::Ractor.make_shareable(message)) if port.is_a?(Atom)
          port.send(message, move:)
        rescue ::Ractor::ClosedError
          # An interrupted caller closes its private reply port.
          raise unless port.is_a?(ReplyPort) && port.closed?
        end
      end

      def initialize
        @ractor = ::Ractor.new { Manager.new.run }
        ::Ractor.make_shareable(self)
      end

      private

      def execute(action, key, value = nil, move: false)
        raise Ractor::IsolationError, "key must be shareable" unless ::Ractor.shareable?(key)
        raise ThreadError, "deadlock; recursive access from the Vault Ractor" if ::Ractor.current.equal?(@ractor)
        port = ReplyPort.new
        @ractor.send([action, key, value, port].freeze, move:)
        success, payload = port.receive
        success ? payload : raise(payload)
      ensure
        port&.close
      end
    end
  end
end
