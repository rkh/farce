# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Strict
    # A Ractor-shareable concurrent map that stores shareable keys and values directly.
    # Updates on different keys can run concurrently.
    # Clearing the map invalidates unfinished updates so they cannot restore removed entries.
    #
    # @example Atomically counting occurrences
    #   counts = Farce::Strict::Map.new
    #   counts.upsert(:ruby, 1) { |count| count + 1 } # => 1
    #   counts.upsert(:ruby, 1) { |count| count + 1 } # => 2
    class Map < Abstract::ConcurrentMap
      include Shareable

      def initialize(
        initial_mapping = nil,
        normalize_keys: nil,
        compare_by_identity: false,
        compare_keys_by_identity: compare_by_identity,
        compare_values_by_identity: compare_by_identity
      )
        raise TypeError, "initial mapping must be a Hash" unless initial_mapping.nil? || initial_mapping.is_a?(Hash)
        restoring  = Internal::KeyNormalizer.restoration?(normalize_keys)
        normalizer = Internal::KeyNormalizer.build(normalize_keys, shareable: true)
        @map       = Internal::StrictMap.new(
          normalizer && !restoring ? nil : initial_mapping,
          compare_by_identity:,
          compare_keys_by_identity:,
          compare_values_by_identity:,
        )
        Internal::KeyNormalizer.install_concurrent(self, normalizer) unless restoring
        initial_mapping&.each { self[_1] = _2 } if normalizer && !restoring
        Internal::KeyNormalizer.install_concurrent(self, normalizer) if restoring
        super()
      end

      def shareable_keys? = true
      def shareable_values? = true
    end
  end
end
