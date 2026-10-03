# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Lease pool storage that retains shareable resource references directly.
    class StrictLeasePool < LeasePoolState
      include Freeze::Unfreezable

      private

      def initialize_storage               = @resources = StrictMap.new(compare_by_identity: true)
      def finalize_initialization          = Freeze.publish(self)
      def store_resource(token, resource)  = @resources.store(token, resource)
      def take_resource(token)             = @resources.delete(token)
      def return_resource(token, resource) = store_resource(token, resource)
      def discard_resource(token)          = @resources.delete(token)

      def validate_resource!(resource)
        super
        return if Ractor.shareable?(resource)

        raise Ractor::IsolationError, "lease pool resource must be Ractor-shareable"
      end
    end
  end
end
