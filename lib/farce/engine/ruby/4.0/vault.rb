# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/ruby/shared/vault"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Vault
      class Manager
        private def receive_request = ::Ractor.receive

        private def respond(port, message, move: false)
          return port.store(::Ractor.make_shareable(message)) if port.is_a?(Atom)
          port.send(message, move:)
        rescue ::Ractor::ClosedError
          # An interrupted caller closes its private reply port.
          raise unless port.is_a?(::Ractor::Port) && port.closed?
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
        port = ::Ractor::Port.new
        @ractor.send([action, key, value, port].freeze, move:)
        success, payload = port.receive
        success ? payload : raise(payload)
      ensure
        port&.close
      end
    end
  end
end
