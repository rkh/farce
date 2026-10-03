# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Strict
    # A Ractor-shareable map that stores independently leased shareable resources directly.
    # Initial resources, insertions, and replacements must be shareable. They are
    # not automatically frozen. Other references remain usable, so callers must
    # honor the checkout when accessing mutable resources.
    #
    # @example Updating shareable resources in an automatic lease scope
    #   leases = Farce::Strict::LeaseMap.new do
    #     { primary: Farce::Strict::Map.new, replica: Farce::Strict::Map.new }
    #   end
    #   leases.auto_lease do
    #     leases[:primary][:status] = :ready
    #     leases[:replica][:status] = :ready
    #   end
    #   leases.checkout(:primary) { |state| state[:status] } # => :ready
    class LeaseMap < Abstract::LeaseMap
      include Shareable::Unfreezable

      def shareable_values? = true

      private

      def new_internal_lease_map(mapping)
        Internal::StrictLeaseMap.new(mapping, lease_class: Farce::Strict::Lease, registry_class: Farce::Strict::Map)
      end
    end
  end
end
