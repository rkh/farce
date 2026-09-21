# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Local
    # A shareable lease map with independently initialized resources in each scope.
    #
    # @example Keeping independent resources in each Fiber
    #   leases = Farce::Local::LeaseMap.new(scope: :fiber) { { jobs: [] } }
    #   leases.checkout(:jobs) { |jobs| jobs << :parent }
    #   Fiber.new { leases.checkout(:jobs, &:dup) }.resume # => []
    #   leases.checkout(:jobs, &:dup) # => [:parent]
    class LeaseMap < Abstract::LeaseMap
      include Shareable::Unfreezable
      include Scoped

      # Create a map that initializes once on first use in each scope.
      # @!macro scopes
      # @param scope [Symbol] the scope of the lease map
      # @yield builds the initial mapping for each initialized scope
      # @yieldreturn [Hash, Farce::Abstract::Map, #each] the initial mapping for that scope
      def initialize(scope: :ractor, normalize_keys: nil, &initializer)
        raise ArgumentError, "a resource constructor block is required" unless initializer

        @initializer = Ractor.shareable?(initializer) ? initializer : Ractor.shareable_proc(&initializer)
        super(scope:, normalize_keys:)
      end

      private

      def eager_scoped_value? = false
      def new_scoped_value    = Internal::LeaseInitialization.new
      def internal_lease_map  = scoped_lease_map

      def checkout_canonical(key, missing_key:, timeout: nil, &)
        deadline = timeout_deadline(timeout)
        map      = scoped_lease_map(timeout: remaining_timeout(deadline))
        raise TimeoutError, "lease checkout timed out" unless map

        map.checkout(key, timeout: remaining_timeout(deadline), receiver: self, missing_key:, &)
      end

      def try_checkout_canonical(key, missing_key:, &)
        map = scoped_lease_map(wait: false)
        return unless map

        map.try_checkout(key, receiver: self, missing_key:, &)
      end

      def scoped_lease_map(**)
        scoped_value.fetch(**) do
          mapping = prepare_initial_resources(@initializer.call, @key_normalizer)
          Internal::LeaseMap.new(
            mapping,
            lease_class:    Farce::Unshared::Lease,
            registry_class: Farce::Unshared::Map,
          )
        end
      end

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
