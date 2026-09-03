# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/ruby/shared/vault"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Vault
      class Manager
        private def respond(_, ...) = ::Ractor.yield(...)
      end

      def initialize
        @lock   = Lock.new
        @ractor = ::Ractor.new { Manager.new.run }
        ::Ractor.make_shareable(self)
      end

      private

      def execute(action, key, value = nil, move: false)
        raise Ractor::IsolationError, "key must be shareable" unless ::Ractor.shareable?(key)
        @lock.synchronize do
          @ractor.send([action, key, value, nil].freeze, move:)
          success, payload = @ractor.take
          success ? payload : raise(payload)
        end
      end
    end
  end
end
