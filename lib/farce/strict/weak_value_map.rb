# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Strict
    # A Ractor-shareable concurrent map with strong shareable keys and weak shareable values.
    #
    # @example Caching a value without keeping it alive
    #   value = Object.new.freeze
    #   map   = Farce::Strict::WeakValueMap.new({ result: value })
    #   map[:result].equal?(value) # => true
    #
    #   # The entry can disappear once its value is collected.
    #   value = nil
    class WeakValueMap < Abstract::WeakValueMap
      include Shareable

      def initialize(
        initial_mapping = nil,
        normalize_keys: nil,
        compare_by_identity: false,
        compare_keys_by_identity: compare_by_identity,
        compare_values_by_identity: compare_by_identity
      )
        initial_mapping = convert_entries(initial_mapping)
        restoring  = Internal::KeyNormalizer.restoration?(normalize_keys)
        normalizer = Internal::KeyNormalizer.build(normalize_keys, shareable: true)
        populate   = initial_mapping && ((normalizer && !restoring) || !initial_mapping.is_a?(Hash))
        @map       = Internal::StrictWeakValueMap.new(
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

      def shareable_keys? = true
      def shareable_values? = true
    end
  end
end
