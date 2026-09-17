# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Unsafe
    # @!macro unsafe
    # An LFU map for caches whose caller provides exclusive access to composed operations.
    # Individual storage operations retain the engine backend's integrity guard. Cache loading
    # does not coordinate competing callers, including callers loading the same key.
    class LFUMap < Abstract::LFUMap
      include Unshareable

      # @!method store_if_absent(key)
      #   Read an existing value or construct and store a value for an absent key.
      #   Competing callers can run the loader concurrently, including for equal keys.
      #   The caller must provide exclusive access when a single initialization is required.
      #   @param key [BasicObject] The key to retrieve or initialize.
      #   @yieldreturn [BasicObject] The value to store.
      #   @return [BasicObject] The existing or newly stored value.
      #   @raise [LocalJumpError] If no block is given.

      # (see Abstract::Map#[])
      def []=(key, value)
        internal_map[prepare_key(key)] = value
        value
      end

      private

      def new_bounded_map(...) = Internal::LFUMap.new(...)
      def new_key_locks(**)    = nil
      def with_key_lock(_key)  = yield
    end
  end
end
