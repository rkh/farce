# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Strict
    # A Ractor-shareable LRU map that stores shareable values directly.
    # Keys must be shareable, except equality-mode mutable strings that can be snapshotted.
    class LRUMap < Abstract::LRUMap
      include Shareable::Delegated

      # (see Abstract::Map#shareable_keys?)
      def shareable_keys? = true

      # (see Abstract::Map#shareable_values?)
      def shareable_values? = true

      private

      def new_bounded_map(...) = Internal::StrictLRUMap.new(...)
      def freeze_backend       = internal_map

      def new_key_locks(compare_keys_by_identity:)
        Internal::KeyLockMap.new(registry_class: Farce::Strict::Map, compare_keys_by_identity:)
      end
    end
  end
end
