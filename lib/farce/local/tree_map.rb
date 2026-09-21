# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Local
    # A shareable tree map with independent mutable storage in each scope.
    #
    # @!method initialize(entries = nil, scope: :ractor)
    #   @!macro scopes
    #   @param entries [Hash, Farce::Abstract::Map, #each, #to_hash, nil] the entries to store initially
    #   @param scope [Symbol] the scope of the tree map
    #   @return [TreeMap]
    class TreeMap < Abstract::TreeMap
      include Shareable::Tracked
      include Scoped::Tracked

      State = Data.define(:map, :key_locks)
      private_constant :State

      protected

      def internal_map = scoped_value.map

      private

      def freeze_scoped_value(state) = state.map.freeze

      def new_copied_scoped_value(map)
        State.new(map, Internal::OrderedKeyLockMap.new)
      end

      def with_key_lock(key, &) = scoped_value.key_locks.synchronize(key, &)

      def new_scoped_value(entries = nil, **)
        unless Internal::KeyNormalizer.canonical_entries?(entries)
          return State.new(Internal::TreeMap.new(entries, **), Internal::OrderedKeyLockMap.new)
        end

        map = Internal::TreeMap.new(nil, **)
        entries.each { map[_1] = _2 }
        State.new(map, Internal::OrderedKeyLockMap.new)
      end
    end
  end
end
