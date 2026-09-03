# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/ruby/shared/vault"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Vault
      class Manager
        private def respond(port, ...) = port.send(...)
      end

      private

      def execute(action, key, value = nil, move: false)
        raise Ractor::IsolationError, "key must be shareable" unless ::Ractor.shareable?(key)
        port,    mutex   = Storage.store_if_absent(self) { [::Ractor::Port.new, Mutex.new] }
        success, payload = mutex.synchronize do
          @ractor.send([action, key, value, port].freeze, move:)
          port.receive
        end
        success ? payload : raise(payload)
      end
    end
  end
end
