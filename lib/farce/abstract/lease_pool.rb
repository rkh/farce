# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract Shared checkout, return, ownership, and capacity behavior for resource pools.
    class LeasePool
      # Construct an empty pool whose resources are created on demand.
      # @param max_size [Integer] the maximum number of managed resources
      # @yield builds one resource after capacity has been reserved
      # @yieldreturn [BasicObject] a new resource
      # @raise [ArgumentError] if no block is given or max_size is not a positive Integer
      def initialize(max_size:, &factory)
        validate_configuration!(max_size, factory)
        @max_size = Integer(max_size)
        @factory  = prepare_factory(factory)
        @pool     = new_internal_pool(max_size)
        super()
      end

      # Acquire a resource, waiting for availability or creation capacity.
      # @param timeout [Numeric, nil] maximum seconds to wait before reserving a resource
      # @yieldparam resource [BasicObject] the acquired resource
      # @return [BasicObject] the resource without a block, or the block result
      # @raise [Farce::TimeoutError] if the timeout expires
      def checkout(timeout: nil, &block)
        pool = internal_pool
        block ? pool.checkout(@factory, timeout:, &block) : pool.checkout(@factory, timeout:)
      end

      # Acquire an available resource or create one without waiting for capacity.
      # @yieldparam resource [BasicObject] the acquired resource
      # @return [BasicObject, nil] the resource or block result, or nil at capacity
      def try_checkout(&block)
        pool = internal_pool
        block ? pool.try_checkout(@factory, &block) : pool.try_checkout(@factory)
      end

      # Return an explicitly checked-out resource, a replacement, or nil to delete its slot.
      # @param resource [BasicObject, nil] the resource to store, or nil to release capacity
      # @return [self]
      # @raise [Farce::OwnershipError] unless the current Fiber owns an explicit checkout
      # @raise [ArgumentError] if resource is true or false
      def checkin(resource)
        internal_pool.checkin(resource)
        self
      end

      # @return [Integer] the configured capacity
      attr_reader :max_size

      # @return [Integer] managed resources, excluding in-progress factory calls
      def size = internal_pool.size

      # @return [Integer] resources ready for checkout
      def available_count = internal_pool.available_count

      # @return [Integer] resources currently checked out
      def checked_out_count = internal_pool.checked_out_count

      # @return [Integer] capacity reserved by in-progress factory calls
      def creating_count = internal_pool.creating_count

      private

      def validate_configuration!(max_size, factory)
        raise ArgumentError, "a resource factory block is required" unless factory
        return if max_size.is_a?(Integer) && max_size.positive?

        raise ArgumentError, "max_size must be a positive Integer"
      end

      def prepare_factory(factory) = factory
      def internal_pool = @pool
      def new_internal_pool(_) = raise(NoMethodError, "abstract lease pool storage")
    end
  end
end
