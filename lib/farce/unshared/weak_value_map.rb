# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Unshared
    # A thread-safe map with weak values for use within one Ractor.
    #
    # @example Caching a mutable value without keeping it alive
    #   value = []
    #   map   = Farce::Unshared::WeakValueMap.new({ result: value })
    #   map[:result].equal?(value) # => true
    #
    #   # The entry can disappear once its value is collected.
    #   value = nil
    class WeakValueMap < Abstract::WeakValueMap
      include Unshareable

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
        @map       = Internal::UnsharedWeakValueMap.new(
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
