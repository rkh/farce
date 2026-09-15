# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Unshared
    # A thread-safe lease that passes one resource directly within a Ractor.
    #
    # @example Updating one object from multiple threads
    #   lease = Farce::Unshared::Lease.new { { count: 0 } }
    #   workers = 3.times.map do
    #     Thread.new do
    #       lease.checkout { |state| state[:count] += 1 }
    #     end
    #   end
    #   workers.each(&:join)
    #
    #   lease.checkout { |state| state[:count] } # => 3
    class Lease < Abstract::Lease
      include Unshareable

      private

      def new_internal_lease(resource) = Internal::UnsharedLease.new(resource)
    end
  end
end
