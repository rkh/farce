# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Unshared
    # A thread-safe set maintained in ascending order within one Ractor.
    class SortedSet < Farce::Abstract::SortedSet
      include Unshareable

      class MutableTreeMap < Farce::Unshared::TreeMap # :nodoc:
        private

        def prepare_key(key) = key
        def new_key_locks = Internal::MutableOrderedKeyLockMap.new
        def new_tree_map(...) = Internal::MutableTreeMap.new(...)
      end
      private_constant :MutableTreeMap

      private

      def new_map(entries = nil, compare_keys_by_identity: false, **)
        raise ArgumentError, "sorted sets do not support identity comparison" if compare_keys_by_identity
        MutableTreeMap.new(entries)
      end
    end
  end
end
