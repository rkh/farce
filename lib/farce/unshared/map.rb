# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Unshared
    # A thread-safe concurrent map for mutable objects used within one Ractor.
    # Updates on different keys can run concurrently.
    # Clearing the map invalidates unfinished updates so they cannot restore removed entries.
    class Map < Abstract::ConcurrentMap
      include Unshareable

      # Create a map that strongly retains its keys and values.
      #
      # @example Atomically updating a mutable value
      #   counters = Farce::Unshared::Map.new({ jobs: [] })
      #   counters.update(:jobs) { |jobs| jobs << :finished }
      #   counters[:jobs] # => [:finished]
      #
      # @param initial_mapping [Hash, Farce::Abstract::Map, #each, nil] The entries to store initially.
      # @param compare_by_identity [Boolean] Whether keys and values are compared by identity.
      # @param compare_keys_by_identity [Boolean] Whether keys are compared by identity.
      # @param compare_values_by_identity [Boolean] Whether values are compared by identity.
      def initialize(
        initial_mapping = nil,
        normalize_keys: nil,
        compare_by_identity: false,
        compare_keys_by_identity: compare_by_identity,
        compare_values_by_identity: compare_by_identity
      )
        initial_mapping = convert_entries(initial_mapping)
        restoring  = Internal::KeyNormalizer.restoration?(normalize_keys)
        normalizer = Internal::KeyNormalizer.build(normalize_keys, shareable: false)
        populate   = initial_mapping && ((normalizer && !restoring) || !initial_mapping.is_a?(Hash))
        @map       = Internal::UnsharedMap.new(
          populate ? nil : initial_mapping,
          compare_by_identity:,
          compare_keys_by_identity:,
          compare_values_by_identity:,
        )
        Internal::KeyNormalizer.install_concurrent(self, normalizer) unless restoring
        initial_mapping.each { |key, value| self[key] = value } if populate
        Internal::KeyNormalizer.install_concurrent(self, normalizer) if restoring
        super()
      end
    end
  end
end
