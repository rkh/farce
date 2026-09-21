# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Lease storage that passes its resource directly within one Ractor.
    class UnsharedLease < LeaseState
      include Freeze::Unfreezable

      private

      def initialize_resource(resource)
        @resource = resource
      end

      def take_resource
        resource  = @resource
        @resource = nil
        resource
      end

      def return_resource(resource)
        @resource = resource
      end
    end
  end
end
