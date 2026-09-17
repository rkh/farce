# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Local
    # A shareable tree map with independent mutable storage in each scope.
    #
    # @!method initialize(entries = nil, scope: :ractor)
    #   @!macro scopes
    #   @param entries [Hash, #to_hash, nil] the entries to store initially
    #   @param scope [Symbol] the scope of the tree map
    #   @return [TreeMap]
    class TreeMap < Abstract::TreeMap
      include Scoped

      State = Data.define(:map, :key_locks)
      private_constant :State

      private

      def internal_map          = scoped_value.map
      def with_key_lock(key, &) = scoped_value.key_locks.synchronize(key, &)

      def new_scoped_value(...)
        State.new(Internal::TreeMap.new(...), Internal::OrderedKeyLockMap.new)
      end
    end
  end
end
