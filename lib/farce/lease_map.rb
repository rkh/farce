# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A Ractor-shareable map that moves each resource on checkout and checkin.
  #
  # @example Updating independently leased resources
  #   leases = Farce::LeaseMap.new { { primary: [], replica: [] } }
  #   leases.checkout(:primary) { |items| items << :updated }
  #   leases.checkout(:primary, &:dup) # => [:updated]
  #
  # @example Automatically checking out resources as they are accessed
  #   leases = Farce::LeaseMap.new { { primary: [], replica: [] } }
  #
  #   leases.auto_lease do
  #     leases[:primary] << :updated
  #     leases[:replica] << :replicated
  #     leases[:primary] << :verified # Reuses the same checkout
  #   end
  #
  #   # Both resources are checked back in when the block exits, even on an exception.
  #   leases.available?(:primary) # => true
  #   leases.checkout(:primary, &:dup) # => [:updated, :verified]
  class LeaseMap < Farce::Abstract::LeaseMap
    include Shareable::Unfreezable

    private

    def new_internal_lease_map(mapping)
      Internal::LeaseMap.new(mapping, lease_class: Farce::Lease, registry_class: Farce::Map)
    end
  end
end
