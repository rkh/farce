# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Validate shareable resources before publishing or replacing map leases.
    class StrictLeaseMap < LeaseMap
      private

      def validate_resource!(resource)
        super
        return if Ractor.shareable?(resource)

        raise Ractor::IsolationError, "lease resource must be Ractor-shareable"
      end
    end
  end
end
