# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Strict
    # A Ractor-shareable LFU map that stores shareable values directly.
    class LFUMap < Abstract::LFUMap
      include Shareable

      # (see Abstract::Map#shareable_keys?)
      def shareable_keys? = true

      # (see Abstract::Map#shareable_values?)
      def shareable_values? = true

      private

      def new_bounded_map(...) = Internal::StrictLFUMap.new(...)

      def new_key_locks(compare_keys_by_identity:)
        Internal::KeyLockMap.new(registry_class: Farce::Strict::Map, compare_keys_by_identity:)
      end
    end
  end
end
