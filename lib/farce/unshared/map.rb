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
      # @param initial_mapping [Hash, nil] The entries to store initially.
      # @param compare_by_identity [Boolean] Whether keys and values are compared by identity.
      # @param compare_keys_by_identity [Boolean] Whether keys are compared by identity.
      # @param compare_values_by_identity [Boolean] Whether values are compared by identity.
      def initialize(
        initial_mapping = nil,
        compare_by_identity: false,
        compare_keys_by_identity: compare_by_identity,
        compare_values_by_identity: compare_by_identity
      )
        @map = Internal::UnsharedMap.new(
          initial_mapping,
          compare_by_identity:,
          compare_keys_by_identity:,
          compare_values_by_identity:,
        )
        super()
      end
    end
  end
end
