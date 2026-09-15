# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract Shared checkout, return, ownership, and retirement behavior for leases.
    class Lease
      # Construct a lease from one resource-building block.
      # @yield builds the resource managed by the lease
      # @yieldreturn [BasicObject] the initial resource
      # @raise [ArgumentError] if no block is given or the resource is nil or boolean
      def initialize
        raise ArgumentError, "a resource constructor block is required" unless block_given?

        @lease = new_internal_lease(yield)
        super
      end

      # Acquire the resource, waiting until it is available.
      # @param timeout [Numeric, nil] maximum seconds to wait
      # @yieldparam resource [BasicObject] the acquired resource
      # @return [BasicObject] the resource without a block, or the block result
      # @raise [Farce::TimeoutError] if the timeout expires
      # @raise [Farce::RetiredLeaseError] if the lease is retired
      def checkout(timeout: nil, &block)
        lease = internal_lease
        block ? lease.checkout(timeout:, &block) : lease.checkout(timeout:)
      end

      # Acquire the resource immediately if it is available.
      # @yieldparam resource [BasicObject] the acquired resource
      # @return [BasicObject, nil] the resource or block result, or nil when unavailable
      # @raise [Farce::RetiredLeaseError] if the lease is retired
      def try_checkout(&block)
        lease = internal_lease
        block ? lease.try_checkout(&block) : lease.try_checkout
      end

      # Return an explicitly checked-out resource or a replacement.
      # @param resource [BasicObject] the resource to store
      # @return [self]
      # @raise [Farce::OwnershipError] unless the current Fiber owns an explicit checkout
      # @raise [Farce::RetiredLeaseError] if the lease is retired
      # @raise [ArgumentError] if the resource is nil or boolean
      def checkin(resource)
        internal_lease.checkin(resource)
        self
      end

      # Permanently retire this lease and wake its waiters.
      #
      # The current Fiber must own the checkout. Retirement ends that checkout,
      # so automatic block cleanup does not return the resource. The resource is
      # not closed or otherwise disposed. Calling this again after retirement is safe.
      # @return [self]
      # @raise [Farce::OwnershipError] unless the current Fiber owns the checkout
      def retire
        internal_lease.retire
        self
      end

      # @return [Boolean] whether the resource is available for checkout
      def available? = internal_lease.available?

      # @return [Boolean] whether the resource is checked out
      def checked_out? = internal_lease.checked_out?

      # @return [Boolean] whether the current Fiber owns the checkout
      def owned? = internal_lease.owned?

      # @return [Boolean] whether the lease has been permanently retired
      def retired? = internal_lease.retired?

      private

      def checkout_with_handoff(...)       = internal_lease.checkout_with_handoff(...)
      def try_checkout_with_handoff(...)   = internal_lease.try_checkout_with_handoff(...)
      def checkin_scope(resource)          = internal_lease.checkin_scope(resource)
      def explicitly_owned?                = internal_lease.explicitly_owned?
      def mark_scope_managed               = internal_lease.mark_scope_managed
      def scope_managed?                   = internal_lease.scope_managed?
      def owned_resource                   = internal_lease.owned_resource
      def replace_owned_resource(resource) = internal_lease.replace_owned_resource(resource)
      def internal_lease                   = @lease
      def new_internal_lease(_)            = raise(NoMethodError, "abstract lease storage")
    end
  end
end
