# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Lease storage that moves its resource through the engine Vault.
    class Lease < LeaseState
      include Freeze::Unfreezable

      VAULT = Vault.new
      private_constant :VAULT

      private

      def initialize_resource(resource)
        Freeze.publish(self)
        VAULT.move_in(self, resource)
      end

      def take_resource             = VAULT.move_out(self)
      def return_resource(resource) = VAULT.move_in(self, resource)
    end
  end
end
