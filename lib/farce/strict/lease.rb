# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Strict
    # A Ractor-shareable lease that stores a shareable resource directly.
    # Construction and checkin reject non-shareable resources without freezing them.
    # Checkout coordinates callers. Other references remain usable, so callers
    # must honor the checkout when accessing a mutable resource.
    #
    # @example Coordinating several changes to shareable state
    #   lease = Farce::Strict::Lease.new { Farce::Strict::Map.new }
    #   lease.checkout do |state|
    #     state[:status] = :ready
    #     state[:generation] = 1
    #   end
    #   lease.checkout { |state| state[:status] } # => :ready
    class Lease < Abstract::Lease
      include Shareable::Unfreezable

      private

      def new_internal_lease(resource) = Internal::StrictLease.new(resource)
    end
  end
end
