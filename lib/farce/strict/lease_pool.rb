# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Strict
    # A Ractor-shareable pool that stores shareable resources directly.
    # Factory results and checkin replacements must be shareable. They are not
    # automatically frozen. Other references remain usable during checkout,
    # so callers must honor the checkout when accessing mutable resources.
    #
    # @example Reusing shareable resources with bounded concurrency
    #   pool = Farce::Strict::LeasePool.new(max_size: 2) { Farce::Strict::Map.new }
    #   pool.checkout { |state| state[:uses] = (state[:uses] || 0) + 1 }
    #   pool.checkout { |state| state[:uses] } # => 1
    class LeasePool < Abstract::LeasePool
      include Shareable::Unfreezable

      private

      def prepare_factory(factory)
        Ractor.shareable?(factory) ? factory : Ractor.shareable_proc(&factory)
      end

      def new_internal_pool(max_size) = Internal::StrictLeasePool.new(max_size)
    end
  end
end
