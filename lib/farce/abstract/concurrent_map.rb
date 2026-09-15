# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract Super class for {Map maps} with added concurrency features.
    class ConcurrentMap < Map
      # (see Map#[])
      def [](key) = internal_map[key]

      # (see Map#[]=)
      def []=(key, value)
        internal_map[key] = value
      end

      # (see Map#fetch)
      def fetch(*arguments)
        unless arguments.length.between?(1, 2)
          raise ArgumentError, "wrong number of arguments (given #{arguments.length}, expected 1..2)"
        end

        key, default = arguments
        warn "block supersedes default value argument", uplevel: 1 if block_given? && arguments.length == 2
        internal_map.fetch(key) do
          return yield(key) if block_given?
          return default if arguments.length == 2
          raise KeyError.new("key not found: #{key.inspect}", receiver: self, key: key)
        end
      end

      # Read the value associated with a key, waiting for atomic-update access if necessary.
      # @param key [BasicObject] The key to look up.
      # @param timeout [Numeric, nil] The maximum number of seconds to wait for access.
      # @yield Called if access cannot be acquired before the timeout.
      # @yieldreturn [BasicObject] The fallback value to return.
      # @return [BasicObject, nil]
      #   The associated value, nil if the key is absent, or the fallback result if the operation times out.
      def get(key, timeout: nil, &) = internal_map.get(key, timeout:, &)

      # Associate a value with a key, waiting for atomic-update access if necessary.
      # @param key [BasicObject] The key to store.
      # @param value [BasicObject] The value to store.
      # @param timeout [Numeric, nil] The maximum number of seconds to wait for access.
      # @yield Called if access cannot be acquired before the timeout.
      # @yieldreturn [BasicObject] The fallback value to return.
      # @return [BasicObject, nil] `value` on success, or the fallback result or nil on timeout.
      def store(key, value, timeout: nil, &) = internal_map.store(key, value, timeout:, &)

      # Replace the value associated with a key and return its previous value.
      # @param key [BasicObject] The key to update.
      # @param replacement [BasicObject] The value to store.
      # @param timeout [Numeric, nil] The maximum number of seconds to wait for access.
      # @yield Called if access cannot be acquired before the timeout.
      # @yieldreturn [BasicObject] The fallback value to return.
      # @return [BasicObject, nil]
      #   The previous value, nil if the key was absent, or the fallback result if the operation times out.
      def swap(key, replacement, timeout: nil, &) = internal_map.swap(key, replacement, timeout:, &)

      # Atomically fetch an existing value or compute and store a value for an absent key.
      # @param key [BasicObject] The key to look up or store.
      # @param timeout [Numeric, nil] The maximum number of seconds to wait for access.
      # @yield Called without arguments when the key is absent.
      # @yieldreturn [BasicObject] The value to store and return.
      # @return [BasicObject, nil] The existing or newly stored value, or nil on timeout.
      # @raise [LocalJumpError] If no block is given.
      def store_if_absent(key, timeout: nil, &) = internal_map.store_if_absent(key, timeout:, &)

      # Atomically replace a value if the key is present and its current value matches `expected`.
      # The configured value-comparison mode determines whether matching uses equality or identity.
      # @param key [BasicObject] The key to update.
      # @param expected [BasicObject] The value expected to be currently associated with the key.
      # @param replacement [BasicObject] The value to store when the current value matches.
      # @param timeout [Numeric, nil] The maximum number of seconds to wait for access.
      # @return [Boolean] Whether the value was replaced. Returns false on timeout.
      def compare_and_set(key, expected, replacement, timeout: nil)
        internal_map.compare_and_set(key, expected, replacement, timeout:)
      end

      # Atomically replace the value associated with a key with the block result.
      # The block receives nil when the key is absent or its current value is nil.
      # @param key [BasicObject] The key to update.
      # @param timeout [Numeric, nil] The maximum number of seconds to wait for access.
      # @yield [value] Called after access is acquired.
      # @yieldparam value [BasicObject, nil] The current value, or nil if the key is absent.
      # @yieldreturn [BasicObject] The value to store and return.
      # @return [BasicObject, nil] The newly stored value, or nil on timeout.
      # @raise [LocalJumpError] If no block is given.
      def update(key, timeout: nil, &) = internal_map.update(key, timeout:, &)

      # Atomically insert `initial` for an absent key or replace an existing value with the block result.
      # The block is not called when the key is absent.
      # @param key [BasicObject] The key to insert or update.
      # @param initial [BasicObject] The value to store when the key is absent.
      # @param timeout [Numeric, nil] The maximum number of seconds to wait for access.
      # @yield [value] Called when the key is present.
      # @yieldparam value [BasicObject] The current value.
      # @yieldreturn [BasicObject] The replacement value to store and return.
      # @return [BasicObject, nil] The initial or replacement value, or nil on timeout.
      # @raise [LocalJumpError] If no block is given.
      def upsert(key, initial, timeout: nil, &) = internal_map.upsert(key, initial, timeout:, &)

      # Wait until the value associated with a key no longer matches `expected`.
      # An absent key is observed as nil. The configured value-comparison mode determines how values are matched.
      # @param key [BasicObject] The key to observe.
      # @param expected [BasicObject] The value to wait to change from.
      # @param timeout [Numeric, nil] The maximum number of seconds to wait.
      # @yield Called if the value has not changed before the timeout.
      # @yieldreturn [BasicObject] The fallback value to return.
      # @return [BasicObject, nil] The changed value, or the fallback result or nil on timeout.
      def wait_until_changed(key, expected, timeout: nil, &)
        internal_map.wait_until_changed(key, expected, timeout:, &)
      end

      # Wait until a key is associated with a non-nil value.
      # @param key [BasicObject] The key to observe.
      # @param timeout [Numeric, nil] The maximum number of seconds to wait.
      # @yield Called if the value is still nil when the timeout elapses.
      # @yieldreturn [BasicObject] The fallback value to return.
      # @return [BasicObject, nil] The non-nil value, or the fallback result or nil on timeout.
      def wait_until_non_nil(key, timeout: nil, &) = internal_map.wait_until_non_nil(key, timeout:, &)

      # (see Map#key?)
      def key?(key) = internal_map.key?(key)

      # (see Map#getkey)
      def getkey(key) = internal_map.getkey(key)

      # (see Map#size)
      def size = internal_map.size

      # (see Map#compare_keys_by_identity?)
      def compare_keys_by_identity? = internal_map.compare_keys_by_identity?

      # (see Map#compare_values_by_identity?)
      def compare_values_by_identity? = internal_map.compare_values_by_identity?

      # (see Map#keys)
      def keys = internal_map.keys

      # Return the values currently stored in the map.
      # @return [Array<BasicObject>] A new array of values in iteration order.
      def values = each_value.to_a

      # Iterate over entries captured when iteration begins.
      # The map can be modified safely from the block.
      # (see Map#each)
      def each(&block)
        return enum_for(__callee__) { size } unless block

        internal_map.each(&block)
        self
      end

      # (see Map#each_pair)
      alias each_pair each

      # (see Map#each_key)
      def each_key(&block)
        return enum_for(__callee__) { size } unless block

        internal_map.each_key(&block)
        self
      end

      # (see Map#each_value)
      def each_value(&block)
        return enum_for(__callee__) { size } unless block

        internal_map.each_value(&block)
        self
      end

      # (see Map#delete)
      def delete(key) = internal_map.delete(key)

      # (see Map#clear)
      def clear
        internal_map.clear
        self
      end

      private def internal_map = @map
    end
  end
end
