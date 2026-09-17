# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Local
    # A shareable LRU map with independent mutable storage and capacity in each scope.
    #
    # @!method initialize(entries = nil, max_size:, scope: :ractor, **options)
    #   @!macro scopes
    #   @param entries [Hash, Array<Array(BasicObject, BasicObject)>, Abstract::Map, #each, nil]
    #     Initial entries for each new scope. Entries are stored sequentially and may be evicted.
    #   @param max_size [Integer] Maximum entries retained by each new scoped map.
    #   @param scope [Symbol] The scope of the LRU map.
    #   @option options [Boolean] compare_by_identity (false) whether keys and values are compared by identity
    #   @option options [Boolean] compare_keys_by_identity (compare_by_identity) whether keys are compared by identity
    #   @option options [Boolean] compare_values_by_identity (compare_by_identity)
    #     whether values are compared by identity
    #   @return [LRUMap]
    class LRUMap < Abstract::LRUMap
      include Scoped

      State = Data.define(:map, :key_locks)
      private_constant :State

      private

      def internal_map          = scoped_value.map
      def with_key_lock(key, &) = scoped_value.key_locks.synchronize(key, &)

      def new_scoped_value(
        entries = nil,
        compare_by_identity: false,
        compare_keys_by_identity: compare_by_identity,
        **
      )
        entries = convert_entries(entries)
        map     = Internal::LRUMap.new(compare_by_identity:, compare_keys_by_identity:, **)
        entries&.each { map[_1] = _2 }
        locks = Internal::KeyLockMap.new(
          registry_class:           Farce::Unshared::Map,
          compare_keys_by_identity:,
        )
        State.new(map, locks)
      end
    end
  end
end
