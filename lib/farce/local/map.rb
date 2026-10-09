# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Local
    # A shareable map with independent mutable storage in each scope.
    #
    # @!parse
    #   class Map
    #     # @!macro map_initialization
    #     # Initial entries are reused for each new scope.
    #     # @!macro scopes
    #     # @param scope [Symbol] The scope of the map. Defaults to `:ractor`.
    #     # @return [Map]
    #     def initialize(
    #       initial_mapping = nil,
    #       scope: :ractor,
    #       normalize_keys: nil,
    #       compare_by_identity: false,
    #       compare_keys_by_identity: compare_by_identity,
    #       compare_values_by_identity: compare_by_identity
    #     )
    #     end
    #   end
    class Map < Abstract::ConcurrentMap
      include Shareable::Tracked
      include Scoped::Tracked

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
