# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Unshared
    # A thread-safe LFU map for mutable keys and values used within one Ractor.
    class LFUMap < Abstract::LFUMap
      include Unshareable

      private

      def new_bounded_map(...) = Internal::LFUMap.new(...)

      def new_key_locks(compare_keys_by_identity:)
        Internal::KeyLockMap.new(registry_class: Farce::Unshared::Map, compare_keys_by_identity:)
      end
    end
  end
end
