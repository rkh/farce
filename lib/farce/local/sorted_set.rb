# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Local
    # A scoped set maintained in ascending order.
    class SortedSet < Farce::Abstract::SortedSet
      include Shareable::Delegated

      class MutableTreeMap < Farce::Local::TreeMap # :nodoc:
        BackingState = Data.define(:map, :key_locks)
        private_constant :BackingState

        private

        def prepare_key(key) = key

        def new_copied_scoped_value(map)
          BackingState.new(map, Internal::MutableOrderedKeyLockMap.new)
        end

        def new_scoped_value(entries = nil, **)
          unless Internal::KeyNormalizer.canonical_entries?(entries)
            return BackingState.new(
              Internal::MutableTreeMap.new(entries, **),
              Internal::MutableOrderedKeyLockMap.new,
            )
          end

          map = Internal::MutableTreeMap.new(nil, **)
          entries.each { map[_1] = _2 }
          BackingState.new(map, Internal::MutableOrderedKeyLockMap.new)
        end
      end
      private_constant :MutableTreeMap

      # The scope with independent contents.
      # @return [Symbol] The configured scope name.
      def scope = map_backend.scope

      private

      def new_map(entries = nil, compare_keys_by_identity: false, scope: :ractor, **)
        raise ArgumentError, "sorted sets do not support identity comparison" if compare_keys_by_identity
        MutableTreeMap.new(entries, scope:)
      end
    end
  end
end
