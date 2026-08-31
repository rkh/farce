# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @note
    #  The supported methods are generally compatible with their Hash counterparts,
    #  with the notable exception of {#update}.
    #
    # A Hash-like collection suited for concurrent access and modification.
    #
    # Iteration order is implementation-dependent. In particular, insertion order is not guaranteed.
    #
    # Implementations can compare keys and values either by equality or by identity. Operations accepting a
    # `timeout` wait at most that many seconds to acquire the access needed for the operation. A timeout must be a
    # finite, non-negative number; `nil` waits indefinitely.
    #
    # @!method [](key)
    #   Look up a key without waiting for atomic-update access.
    #   @param key [BasicObject] The key to look up.
    #   @return [BasicObject, nil] The associated value, or nil if the key is absent.
    #   @abstract
    #
    # @!method []=(key, value)
    #   Associate a value with a key without a timeout.
    #   @param key [BasicObject] The key to store.
    #   @param value [BasicObject] The value to store.
    #   @return [BasicObject] `value`.
    #   @abstract
    #
    # @!method clear
    #   Remove all entries from the map.
    #   @return [self]
    #   @abstract
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
    # @!method compare_keys_by_identity?
    #   @return [Boolean] Whether keys are compared by identity instead of `hash` and `eql?`.
    #   @abstract
    #
    # @!method compare_values_by_identity?
    #   @return [Boolean] Whether values are compared by identity instead of equality.
    #   @abstract
    #
    # @!method delete(key)
    #   Remove a key and its associated value.
    #   @param key [BasicObject] The key to remove.
    #   @return [BasicObject, nil] The removed value, or nil if the key was absent.
    #   @abstract
    #
    # @!method each
    #   Iterate over the map's key-value pairs.
    #   The entries are captured when iteration begins, so the map can be modified safely from the block. Iteration
    #   order is not guaranteed to match insertion order.
    #   @overload each
    #     @yield [pair] Called once for each entry.
    #     @yieldparam pair [Array<BasicObject>] A two-element `[key, value]` pair.
    #     @return [self]
    #   @overload each
    #     @return [Enumerator] An enumerator over two-element `[key, value]` pairs.
    #   @abstract
    #
    # @!method each_key
    #   Iterate over the keys currently stored in the map.
    #   Keys are not guaranteed to be yielded in insertion order.
    #   @overload each_key
    #     @yield [key] Called once for each stored key.
    #     @yieldparam key [BasicObject] A stored key.
    #     @return [self]
    #   @overload each_key
    #     @return [Enumerator] An enumerator over the stored keys.
    #   @abstract
    #
    # @!method each_pair
    #   Iterate over key-value pairs in the same manner as {#each}.
    #   @see #each
    #   @abstract
    #
    # @!method each_value
    #   Iterate over the values currently stored in the map.
    #   Values are not guaranteed to be yielded in insertion order.
    #   @overload each_value
    #     @yield [value] Called once for each stored value.
    #     @yieldparam value [BasicObject] A stored value.
    #     @return [self]
    #   @overload each_value
    #     @return [Enumerator] An enumerator over the stored values.
    #   @abstract
    #
    # @!method fetch(key, *defaults)
    #   Fetch the value associated with a key, using the same missing-key behavior as Hash#fetch.
    #   If both a default and a block are provided, the block takes precedence and a warning is emitted.
    #   @overload fetch(key)
    #     @param key [BasicObject] The key to look up.
    #     @return [BasicObject] The associated value.
    #     @raise [KeyError] If the key is absent.
    #   @overload fetch(key, default)
    #     @param key [BasicObject] The key to look up.
    #     @param default [BasicObject] The value to return if the key is absent.
    #     @return [BasicObject] The associated value or `default`.
    #   @overload fetch(key)
    #     @param key [BasicObject] The key to look up.
    #     @yield [key] Called if the key is absent.
    #     @yieldparam key [BasicObject] The missing key.
    #     @yieldreturn [BasicObject] The value to return.
    #     @return [BasicObject] The associated value or the block result.
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
    # @!method getkey(key)
    #   Return the stored key that matches a lookup key.
    #   @param key [BasicObject] The key to match.
    #   @return [BasicObject, nil] The matching stored key, or nil if no key matches.
    #   @abstract
    #
    # @!method key?(key)
    #   Test whether a key is present, including when its associated value is nil.
    #   @param key [BasicObject] The key to look up.
    #   @return [Boolean] Whether the key is present.
    #   @abstract
    #
    # @!method keys
    #   Return the keys currently stored in the map.
    #   The returned keys are not guaranteed to be in insertion order.
    #   @return [Array<BasicObject>] A new array containing the stored keys.
    #   @abstract
    #
    # @!method size
    #   Return the number of entries currently in the map.
    #   @return [Integer] The number of entries.
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
    #
    # @abstract
    class Map
      include Enumerable

      # Return a two-element array containing a key and its associated value, if the key is present,
      # or nil if the key is absent.
      # @param key [BasicObject] The key to look up.
      # @return [Array(BasicObject, BasicObject), nil] A two-element `[key, value]` array, or nil if the key is absent.
      def assoc(key)
        value = fetch(key) { return nil }
        [key, value]
      end

      # (see #compare_keys_by_identity?)
      def compare_by_identity? = compare_keys_by_identity?

      # Implements Ruby's [dig interface](https://docs.ruby-lang.org/en/master/language/dig_methods_rdoc.html).
      # @param key [BasicObject] The key to look up.
      # @param rest [Array<BasicObject>] Additional keys to look up in nested maps.
      # @return [BasicObject, nil] The value found at the nested location, or nil if any key is absent or nil.
      def dig(key, *rest)
        value = self[key]
        return value if rest.empty? || value.nil?
        value.dig(*rest)
      end

      # Returns whether the map contains no entries.
      # @return [Boolean] Whether the map is empty.
      def empty? = size.zero?

      # Alias for {#key?}
      def has_key?(...) = key?(...)
      alias member?  has_key?
      alias include? has_key?

      # Fetches the values associated with multiple keys, using the same missing-key behavior as Hash#fetch.
      # @yield [key] Called for each missing key.
      # @yieldparam key [BasicObject] The missing key.
      # @yieldreturn [BasicObject] The value to return for the missing key.
      # @param keys [Array<BasicObject>] The keys to look up.
      # @return [Array<BasicObject>] An array of the associated values.
      def fetch_values(*keys, &) = keys.map { fetch(it, &) }

      # Creates a new Array containing the map's key-value pairs as two-element arrays.
      # @return [Array<Array(BasicObject, BasicObject)>>] A new Array of `[key, value]` arrays.
      def to_a = each_pair.to_a

      # Creates a new Hash containing the map's entries.
      # @return [Hash] A new Hash with the same entries.
      def to_h = each_pair.to_h

      # Fetches the values associated with multiple keys, returning nil for any missing keys.
      # @param keys [Array<BasicObject>] The keys to look up.
      # @return [Array<BasicObject>] An array of the associated values, with nil for any missing keys.
      def values_at(*keys) = keys.map { self[it] }

      # Some maps reference their keys weakly, automatically dropping entries when a key gets garbage-collected.
      # @return [Boolean] Whether the map uses weak references for keys.
      def weak_keys? = false

      # Some maps reference their values weakly, automatically dropping entries when a value gets garbage-collected.
      # @return [Boolean] Whether the map uses weak references for values.
      def weak_values? = false
    end
  end
end
