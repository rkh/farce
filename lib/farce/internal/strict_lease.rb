# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Lease storage that retains shareable resource references directly.
    class StrictLease < LeaseState
      include Freeze::Unfreezable

      private

      def initialize_resource(resource)
        @resource = StrictAtom.new(resource)
        Freeze.publish(self)
      end

      def take_resource             = @resource.swap(nil)
      def return_resource(resource) = @resource.store(resource)

      def validate_resource!(resource)
        super
        return if Ractor.shareable?(resource)

        raise Ractor::IsolationError, "lease resource must be Ractor-shareable"
      end
    end
  end
end
