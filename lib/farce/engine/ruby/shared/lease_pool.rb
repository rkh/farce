# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Lease pool storage that moves resources through the CRuby Vault.
    class LeasePool < LeasePoolState
      VAULT = Vault.new
      private_constant :VAULT

      private

      def finalize_initialization
        Ractor.make_shareable(self)
        freeze
      end

      def store_resource(token, resource)  = VAULT.move_in(token, resource)
      def take_resource(token)             = VAULT.move_out(token)
      def return_resource(token, resource) = VAULT.move_in(token, resource)
      def discard_resource(token)          = VAULT.delete(token)
    end
  end
end
