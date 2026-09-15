# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Local
    # A shareable lease with one independently initialized resource in each scope.
    #
    # @example Keeping an independent object in each Fiber
    #   lease = Farce::Local::Lease.new(scope: :fiber) { { name: :initial } }
    #   lease.checkout { |state| state[:name] = :parent }
    #
    #   Fiber.new do
    #     lease.checkout { |state| state[:name] = :child }
    #   end.resume # => :child
    #
    #   lease.checkout { |state| state[:name] } # => :parent
    class Lease < Abstract::Lease
      include Scoped

      # Create a lease that initializes once on first use in each scope.
      # @!macro scopes
      # @param scope [Symbol] the scope of the lease
      # @yield builds the resource for each initialized scope
      # @yieldreturn [BasicObject] the initial resource for that scope
      def initialize(scope: :ractor, &initializer)
        raise ArgumentError, "a resource constructor block is required" unless initializer

        @initializer = Ractor.shareable?(initializer) ? initializer : Ractor.shareable_proc(&initializer)
        super(scope:)
      end

      # (see Farce::Abstract::Lease#checkout)
      def checkout(timeout: nil, &block)
        deadline = timeout_deadline(timeout)
        lease    = scoped_lease(timeout: remaining_timeout(deadline))
        raise TimeoutError, "lease checkout timed out" unless lease

        timeout = remaining_timeout(deadline)
        block ? lease.checkout(timeout:, &block) : lease.checkout(timeout:)
      end

      # (see Farce::Abstract::Lease#try_checkout)
      def try_checkout(&block)
        lease = scoped_lease(wait: false)
        return unless lease

        block ? lease.try_checkout(&block) : lease.try_checkout
      end

      private

      def eager_scoped_value? = false
      def new_scoped_value    = Internal::LeaseInitialization.new
      def internal_lease      = scoped_lease
      def scoped_lease(**)    = scoped_value.fetch(**) { Internal::UnsharedLease.new(@initializer.call) }

      def timeout_deadline(timeout)
        return if timeout.nil?

        timeout = Float(timeout)
        unless timeout.finite? && !timeout.negative?
          raise ArgumentError, "timeout must be a finite, non-negative number or nil"
        end
        Clock.now + timeout
      end

      def remaining_timeout(deadline)
        return unless deadline

        remaining = deadline - Clock.now
        remaining.positive? ? remaining : 0
      end
    end
  end
end
