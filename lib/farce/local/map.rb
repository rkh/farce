# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Local
    # A shareable map with independent mutable storage in each scope.
    #
    # @!method initialize(initial_mapping = nil, scope: :ractor, **options)
    #   @!macro scopes
    #   @param initial_mapping [Hash, Farce::Abstract::Map, #each, nil] the entries to store initially
    #   @param scope [Symbol] the scope of the map
    #   @option options [Boolean] compare_by_identity (false) whether keys and values are compared by identity
    #   @option options [Boolean] compare_keys_by_identity (compare_by_identity) whether keys are compared by identity
    #   @option options [Boolean] compare_values_by_identity (compare_by_identity)
    #     whether values are compared by identity
    #   @return [Map]
    class Map < Abstract::ConcurrentMap
      include Scoped

      protected

      def internal_map = scoped_value

      private

      def new_scoped_value(entries = nil, **)
        unless @key_normalizer || Internal::KeyNormalizer.canonical_entries?(entries)
          return Internal::UnsharedMap.new(entries, **)
        end

        map = Internal::UnsharedMap.new(nil, **)
        entries&.each { map[_1] = _2 }
        Internal::KeyNormalizer.wrap_concurrent(map, @key_normalizer)
      end
    end
  end
end
