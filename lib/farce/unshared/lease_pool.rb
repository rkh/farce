# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Unshared
    # A thread-safe pool that passes resource references within one Ractor.
    #
    # @example Reusing objects from multiple threads
    #   pool = Farce::Unshared::LeasePool.new(max_size: 1) { { uses: 0 } }
    #   workers = 2.times.map do
    #     Thread.new { pool.checkout { |state| state[:uses] += 1 } }
    #   end
    #   workers.each(&:join)
    #
    #   pool.checkout { |state| state[:uses] } # => 2
    class LeasePool < Abstract::LeasePool
      include Unshareable

      private

      def new_internal_pool(max_size) = Internal::UnsharedLeasePool.new(max_size)
    end
  end
end
