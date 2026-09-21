# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Strict
    # A Ractor-shareable concurrent map that retains shareable keys and values weakly.
    #
    # @example Keeping a relationship while both objects remain alive
    #   key   = Object.new.freeze
    #   value = Object.new.freeze
    #   map   = Farce::Strict::WeakMap.new({ key => value })
    #   map[key].equal?(value) # => true
    #
    #   # The entry can disappear once its key or value is collected.
    #   value = nil
    class WeakMap < Abstract::WeakMap
      include Shareable::Delegated

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
        @map       = Internal::StrictWeakMap.new(
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

      private def freeze_backend = internal_map
    end
  end
end
