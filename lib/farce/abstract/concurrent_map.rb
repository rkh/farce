# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract Super class for {Map maps} with added concurrency features.
    #
    # Maps implement most of the interface provided by Hash,
    # as well as `Concurrent::Map` from the `concurrent-ruby` gem.
    class ConcurrentMap < Map
      include DuplicableMap

      # @api private
      def transaction_wrapper(transaction) = Transaction::Map.new(transaction, self, internal_map)

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

      # Return an existing value or store a default for an absent key.
      # A block takes precedence over the default and receives the original key.
      # The lookup and store are separate operations. Concurrent writes can be overwritten.
      # @param key [BasicObject] The key to look up or store.
      # @param defaults [Array<BasicObject>] At most one default value to store when the key is absent.
      # @see #store For supported transfer and timeout options.
      # @yieldparam key [BasicObject] The original key.
      # @yieldreturn [BasicObject] The value to store.
      # @return [BasicObject, nil] The existing or newly stored value.
      # @raise [KeyError] If the key is absent and neither a default nor a block is provided.
      def fetch_or_store(key, *defaults, **)
        if defaults.size > 1
          raise ArgumentError, "wrong number of arguments (given #{defaults.size + 1}, expected 1..2)"
        end
        return fetch(key) if defaults.empty? && !block_given?
        fetch(key) { store(key, block_given? ? yield(key) : defaults.first, **) }
      end

      # Read the value associated with a key, waiting for atomic-update access if necessary.
      # @param key [BasicObject] The key to look up.
      # @param timeout [Numeric, nil] The maximum number of seconds to wait for access.
      # @yield Called if access cannot be acquired before the timeout.
      # @yieldreturn [BasicObject] The fallback value to return.
      # @return [BasicObject, nil]
      #   The associated value, nil if the key is absent, or the fallback result if the operation times out.
      def get(key, timeout: nil, &) = internal_map.get(key, timeout:, &)

      # Sets a value and returns the previous value.
      # @param key [BasicObject] The key to update.
      # @param value [BasicObject] The value to store.
      # @return [BasicObject, nil] The previous value, or nil if the key was absent.
      def get_and_set(...) = swap(...)

      # Associate a value with a key, waiting for atomic-update access if necessary.
      # @param key [BasicObject] The key to store.
      # @param value [BasicObject] The value to store.
      # @param timeout [Numeric, nil] The maximum number of seconds to wait for access.
      # @yield Called if access cannot be acquired before the timeout.
      # @yieldreturn [BasicObject] The fallback value to return.
      # @return [BasicObject, nil] `value` on success, or the fallback result or nil on timeout.
      def store(key, value, timeout: nil, &) = internal_map.store(key, value, timeout:, &)

      # (see #store)
      def put(...) = store(...)

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

      # (see #store_if_absent)
      def compute_if_absent(...) = store_if_absent(...)

      # Atomically store a value only when the key is absent.
      # Existing nil and false values are preserved.
      # @param key [BasicObject] The key to look up or store.
      # @param value [BasicObject] The value to store when the key is absent.
      # @see #store_if_absent For supported transfer and timeout options.
      # @return [BasicObject, nil] The existing value, or nil when a value was inserted or access timed out.
      def put_if_absent(key, value, **)
        inserted = false
        previous = store_if_absent(key, **) do
          inserted = true
          value
        end
        inserted ? nil : previous
      end

      # Atomically replace an existing value and return its previous value.
      # An absent key is left unchanged. Existing nil and false values can be replaced.
      # @param key [BasicObject] The key to update.
      # @param replacement [BasicObject] The value to store.
      # @param timeout [Numeric, nil] The maximum number of seconds to wait for access.
      # @see #store For supported transfer options.
      # @return [BasicObject, nil] The previous value, or nil when the key is absent or access timed out.
      def replace_if_exists(key, replacement, timeout: nil, **)
        map = internal_map
        previous = nil
        changed = map.modify(key, timeout:) do |present, value|
          next Internal::MAP_KEEP unless present
          previous = value
          map.check_mutation
          wrap_value(replacement, **)
        end
        unwrap_value(previous) if changed
      end

      # Atomically replace the value associated with a key if it is present.
      # The block receives the current value and should return the new value to store.
      # The block is not called for an absent key. A stored nil is passed to the block.
      # @param key [BasicObject] The key to update.
      # @param timeout [Numeric, nil] The maximum number of seconds to wait for access.
      # @yield [value] Called with the current value if the key is present.
      # @yieldparam value [BasicObject] The current value.
      # @yieldreturn [BasicObject] The new value to store.
      # @return [BasicObject, nil] The newly stored value, or nil if the key was absent or the operation timed out.
      # @raise [LocalJumpError] If no block is given.
      def store_if_present(key, timeout: nil)
        raise LocalJumpError, "no block given" unless block_given?
        map = internal_map
        result = nil
        changed = map.modify(key, timeout:) do |present, value|
          next Internal::MAP_KEEP unless present
          replacement = yield(unwrap_value(value))
          map.check_mutation
          result = wrap_value(replacement)
        end
        unwrap_value(result) if changed
      end

      # (see #store_if_present)
      def compute_if_present(...) = store_if_present(...)

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

      # (see #compare_and_set)
      def replace_pair(...) = compare_and_set(...)

      # Atomically remove a key if its current value matches `expected`.
      # The configured value-comparison mode determines whether matching uses equality or identity.
      # Missing keys and mismatched values are left unchanged.
      # @param key [BasicObject] The key to remove.
      # @param expected [BasicObject] The expected current value.
      # @param timeout [Numeric, nil] The maximum number of seconds to wait for access.
      # @return [Boolean] Whether the entry was removed. Returns false on timeout.
      def delete_pair(key, expected, timeout: nil)
        expected = wrap_comparison(expected)
        internal_map.modify(key, timeout:) do |present, value|
          present && values_equal?(value, expected) ? Internal::MAP_DELETE : Internal::MAP_KEEP
        end
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

      # (see #update)
      def compute(...) = update(...)

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

      # (see #upsert)
      def merge_pair(...) = upsert(...)

      # Wait until a block condition matches the current value.
      # One timeout budget covers all checks and waits. The block is not interrupted.
      # @yieldparam value [BasicObject, nil] the current value
      # @yieldreturn [Boolean] whether the value matches
      # An absent key is observed as nil.
      # @param key [BasicObject] the key to observe
      # @param timeout [Numeric, nil] the total seconds available
      # @return [BasicObject, nil] the matching value, or nil on timeout
      # @raise [LocalJumpError] if no block is given
      def wait_until(key, timeout: nil, &) = Internal.wait_until(self, key, timeout:, &)

      # Wait while the block returns a truthy value.
      # @yieldparam value [BasicObject, nil] the current value
      # @yieldreturn [BasicObject] a truthy value to keep waiting, or nil or false to stop
      # @param key [BasicObject] the key to observe
      # @param timeout [Numeric, nil] the total seconds available
      # @return [BasicObject, nil] the value when the condition becomes false, or nil on timeout
      # @raise [LocalJumpError] if no block is given
      def wait_while(key, timeout: nil)
        raise LocalJumpError, "no block given" unless block_given?
        wait_until(key, timeout:) { |value| !yield(value) }
      end

      # Wait while `object === value` is true.
      # @param key [BasicObject] the key to observe
      # @param object [#===] the pattern to stop matching
      # @param timeout [Numeric, nil] the total seconds available
      # @return [BasicObject, nil] the first nonmatching value, or nil on timeout
      def wait_while_match(key, object, timeout: nil)
        wait_while(key, timeout:) { |value| object === value } # rubocop:disable Style/CaseEquality
      end

      # (see #wait_until_changed)
      def wait_while_value(...) = wait_until_changed(...)

      # Wait until the current value equals an object using the configured comparison mode.
      # @param key [BasicObject] the key to observe
      # @param object [BasicObject, nil] the value to compare with the current value
      # @param timeout [Numeric, nil] the total seconds available
      # @return [BasicObject, nil] the matching value, or nil on timeout
      def wait_until_value(key, object, timeout: nil)
        wait_until(key, timeout:) { |value| compare_values_by_identity? ? object.equal?(value) : object == value }
      end

      # Wait until `object === value` is true.
      # @param object [#===] the pattern to match
      # @param timeout [Numeric, nil] the total seconds available
      # @return [BasicObject, nil] the matching value, or nil on timeout
      def wait_until_match(key, object, timeout: nil)
        wait_until(key, timeout:) { |value| object === value } # rubocop:disable Style/CaseEquality
      end

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

      # Iterate incrementally without copying every entry first.
      # Entries can be removed or updated by the block. Insertion or clearing
      # may invalidate traversal and raise RuntimeError. No entry lock is held
      # while the block runs. A small batch of entries may be retained at once.
      # @return [self, Enumerator]
      # @api private
      def each_live
        return enum_for(__method__) { size } unless block_given?
        internal_map.each_live { yield it }
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

      # Delete entries selected by the block and return self.
      #
      # Keys are captured before iteration. Each block and its decision use the existing atomic-update coordination.
      # Blocks see the current value, and keys deleted before their turn are skipped.
      # The whole operation is not atomic. Exceptions leave earlier changes in place.
      # The same reentrancy restrictions as {#update} apply inside each block.
      #
      # @yieldparam key [BasicObject] the stored key
      # @yieldparam value [BasicObject] the current value
      # @return [self, Enumerator]
      def delete_if(&)
        return enum_for(__method__) { size } unless block_given?
        check_frozen! if respond_to?(:check_frozen!, true)
        filter_entries(&)
        self
      end

      # Like {#delete_if}, but return nil when this operation deletes no entries.
      # @return [self, nil, Enumerator]
      def reject!(&)
        return enum_for(__method__) { size } unless block_given?
        check_frozen! if respond_to?(:check_frozen!, true)
        self if filter_entries(&)
      end

      # Remove nil values using per-key update coordination. False values are retained.
      # The whole operation is not atomic, as with {#delete_if}.
      # @return [self, nil] self if this operation deletes entries, otherwise nil.
      def compact! = reject! { |_, value| nil.equal?(value) }

      # Keep entries selected by the block. Uses the same coordination as {#delete_if}.
      # @return [self, Enumerator]
      def keep_if
        return enum_for(__method__) { size } unless block_given?
        check_frozen! if respond_to?(:check_frozen!, true)
        filter_entries { |key, value| !yield(key, value) }
        self
      end

      # Like {#keep_if}, but return nil when this operation deletes no entries.
      # @return [self, nil, Enumerator]
      def select!
        return enum_for(__method__) { size } unless block_given?
        check_frozen! if respond_to?(:check_frozen!, true)
        self if filter_entries { |key, value| !yield(key, value) }
      end
      alias filter! select!

      # Replace each existing value with the block result using atomic-update coordination.
      #
      # Keys are captured before iteration. Missing keys are skipped and earlier changes survive exceptions.
      # Results use this map's transfer mode. The same reentrancy restrictions as {#update} apply.
      #
      # @yieldparam value [BasicObject] the current value
      # @return [self, Enumerator]
      def transform_values!
        return enum_for(__method__) { size } unless block_given?
        check_frozen! if respond_to?(:check_frozen!, true)
        keys.each do |key|
          modify_entry(key, canonical: true) do |present, value|
            present ? yield(value) : Internal::MAP_KEEP
          end
        end
        self
      end

      # Apply input maps in order. A block resolves each collision under atomic-update coordination.
      #
      # Incoming keys use normal lookup rules. Values use this map's transfer mode, including move semantics.
      # The operation is not atomic across keys. Exceptions leave earlier changes in place.
      #
      # @param others [Array<Map, Hash, #to_hash>] mappings to apply in order
      # @yieldparam key [BasicObject] the incoming key
      # @yieldparam old_value [BasicObject] the current value
      # @yieldparam new_value [BasicObject] the incoming value
      # @return [self]
      def merge!(*others)
        check_frozen! if respond_to?(:check_frozen!, true)
        others.each do |other|
          unless Map === other
            other = Hash.try_convert(other) || raise(TypeError, "input must be a Map, Hash, or respond to #to_hash")
          end
          other.each_pair do |key, value|
            if block_given?
              modify_entry(key) { |present, old| present ? yield(key, old, value) : value }
            else
              self[key] = value
            end
          end
        end
        self
      end

      private

      def wrap_comparison(value) = value

      def values_equal?(left, right)
        compare_values_by_identity? ? left.equal?(right) : left == right
      end

      def modify_entry(key, canonical: false)
        map = internal_map
        map = map.instance_variable_get(:@map) if canonical && map.is_a?(Internal::KeyNormalizer::ConcurrentMap)
        map.modify(key) do |present, value|
          replacement = yield(present, present ? unwrap_value(value) : nil)
          next replacement if Internal::MAP_KEEP.equal?(replacement) || Internal::MAP_DELETE.equal?(replacement)
          wrap_value(replacement)
        end
      end

      def filter_entries
        changed = false
        keys.each do |key|
          deleted = modify_entry(key, canonical: true) do |present, value|
            present && yield(key, value) ? Internal::MAP_DELETE : Internal::MAP_KEEP
          end
          changed = true if deleted
        end
        changed
      end

      def copy_map_backend(source, empty: false)
        raise TypeError, "copy this backend through its public map" unless source
        source = source.instance_variable_get(:@map) if source.is_a?(Internal::KeyNormalizer::ConcurrentMap)
        copied = source.class.new(
          compare_keys_by_identity:   source.compare_keys_by_identity?,
          compare_values_by_identity: source.compare_values_by_identity?,
        )
        source.each { |key, value| copied[key] = value } unless empty
        normalizer = instance_variable_get(:@key_normalizer)
        Internal::KeyNormalizer.wrap_concurrent(copied, normalizer)
      end
    end
  end
end
