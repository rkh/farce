# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Unshared
    # A thread-safe map that passes independently leased resources within one Ractor.
    #
    # @example Coordinating mutable resources between threads
    #   leases = Farce::Unshared::LeaseMap.new { { jobs: [] } }
    #   workers = 2.times.map do
    #     Thread.new { leases.checkout(:jobs) { |jobs| jobs << :finished } }
    #   end
    #   workers.each(&:join)
    #   leases.checkout(:jobs, &:length) # => 2
    class LeaseMap < Abstract::LeaseMap
      include Unshareable

      private

      def new_internal_lease_map(mapping)
        Internal::LeaseMap.new(mapping, lease_class: Farce::Unshared::Lease, registry_class: Farce::Unshared::Map)
      end
    end
  end
end
