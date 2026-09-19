# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Unshared
    # A thread-safe map with weak keys and values for use within one Ractor.
    #
    # @example Keeping a relationship while both mutable objects remain alive
    #   key   = Object.new
    #   value = Object.new
    #   map   = Farce::Unshared::WeakMap.new({ key => value })
    #   map[key].equal?(value) # => true
    #
    #   # The entry can disappear once its key or value is collected
    #   value = nil
    class WeakMap < Abstract::WeakMap
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
        @map       = Internal::UnsharedWeakMap.new(
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
