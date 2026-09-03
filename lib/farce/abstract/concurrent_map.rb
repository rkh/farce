# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract Super class for {Map maps} with added concurrency features.
    #
    # @!method compare_and_set(key, expected, replacement, timeout: nil)
    #   Atomically replace a value if the key is present and its current value matches `expected`.
    #   The configured value-comparison mode determines whether matching uses equality or identity.
    #   @param key [BasicObject] The key to update.
    #   @param expected [BasicObject] The value expected to be currently associated with the key.
    #   @param replacement [BasicObject] The value to store when the current value matches.
    #   @param timeout [Numeric, nil] The maximum number of seconds to wait for access.
    #   @return [Boolean] Whether the value was replaced. Returns false on timeout.
    #   @abstract
    #
    # @!method get(key, timeout: nil)
    #   Read the value associated with a key, waiting for atomic-update access if necessary.
    #   @param key [BasicObject] The key to look up.
    #   @param timeout [Numeric, nil] The maximum number of seconds to wait for access.
    #   @yield Called if access cannot be acquired before the timeout.
    #   @yieldreturn [BasicObject] The fallback value to return.
    #   @return [BasicObject, nil]
    #     The associated value, nil if the key is absent, or the fallback result if the operation times out.
    #   @abstract
    #
    # @!method store(key, value, timeout: nil)
    #   Associate a value with a key, waiting for atomic-update access if necessary.
    #   @param key [BasicObject] The key to store.
    #   @param value [BasicObject] The value to store.
    #   @param timeout [Numeric, nil] The maximum number of seconds to wait for access.
    #   @yield Called if access cannot be acquired before the timeout.
    #   @yieldreturn [BasicObject] The fallback value to return.
    #   @return [BasicObject, nil] `value` on success, or the fallback result or nil on timeout.
    #   @abstract
    #
    # @!method store_if_absent(key, timeout: nil)
    #   Atomically fetch an existing value or compute and store a value for an absent key.
    #   @param key [BasicObject] The key to look up or store.
    #   @param timeout [Numeric, nil] The maximum number of seconds to wait for access.
    #   @yield Called without arguments when the key is absent.
    #   @yieldreturn [BasicObject] The value to store and return.
    #   @return [BasicObject, nil] The existing or newly stored value, or nil on timeout.
    #   @raise [LocalJumpError] If no block is given.
    #   @abstract
    #
    # @!method swap(key, replacement, timeout: nil)
    #   Replace the value associated with a key and return its previous value.
    #   @param key [BasicObject] The key to update.
    #   @param replacement [BasicObject] The value to store.
    #   @param timeout [Numeric, nil] The maximum number of seconds to wait for access.
    #   @yield Called if access cannot be acquired before the timeout.
    #   @yieldreturn [BasicObject] The fallback value to return.
    #   @return [BasicObject, nil]
    #     The previous value, nil if the key was absent, or the fallback result if the operation times out.
    #   @abstract
    #
    # @!method update(key, timeout: nil)
    #   Atomically replace the value associated with a key with the block result.
    #   The block receives nil when the key is absent or its current value is nil.
    #   @param key [BasicObject] The key to update.
    #   @param timeout [Numeric, nil] The maximum number of seconds to wait for access.
    #   @yield [value] Called after access is acquired.
    #   @yieldparam value [BasicObject, nil] The current value, or nil if the key is absent.
    #   @yieldreturn [BasicObject] The value to store and return.
    #   @return [BasicObject, nil] The newly stored value, or nil on timeout.
    #   @raise [LocalJumpError] If no block is given.
    #   @abstract
    #
    # @!method upsert(key, initial, timeout: nil)
    #   Atomically insert `initial` for an absent key or replace an existing value with the block result.
    #   The block is not called when the key is absent.
    #   @param key [BasicObject] The key to insert or update.
    #   @param initial [BasicObject] The value to store when the key is absent.
    #   @param timeout [Numeric, nil] The maximum number of seconds to wait for access.
    #   @yield [value] Called when the key is present.
    #   @yieldparam value [BasicObject] The current value.
    #   @yieldreturn [BasicObject] The replacement value to store and return.
    #   @return [BasicObject, nil] The initial or replacement value, or nil on timeout.
    #   @raise [LocalJumpError] If no block is given.
    #   @abstract
    #
    # @!method wait_until_changed(key, expected, timeout: nil)
    #   Wait until the value associated with a key no longer matches `expected`.
    #   An absent key is observed as nil. The configured value-comparison mode determines how values are matched.
    #   @param key [BasicObject] The key to observe.
    #   @param expected [BasicObject] The value to wait to change from.
    #   @param timeout [Numeric, nil] The maximum number of seconds to wait.
    #   @yield Called if the value has not changed before the timeout.
    #   @yieldreturn [BasicObject] The fallback value to return.
    #   @return [BasicObject, nil] The changed value, or the fallback result or nil on timeout.
    #   @abstract
    #
    # @!method wait_until_non_nil(key, timeout: nil)
    #   Wait until a key is associated with a non-nil value.
    #   @param key [BasicObject] The key to observe.
    #   @param timeout [Numeric, nil] The maximum number of seconds to wait.
    #   @yield Called if the value is still nil when the timeout elapses.
    #   @yieldreturn [BasicObject] The fallback value to return.
    #   @return [BasicObject, nil] The non-nil value, or the fallback result or nil on timeout.
    #   @abstract
    class ConcurrentMap < Map
    end
  end
end
