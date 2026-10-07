# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract Superclass for all maps defined by Farce.
    # @note
    #  The supported methods are generally compatible with their Hash counterparts,
    #  with the notable exception of {ConcurrentMap#update}.
    #
    # A Hash-like collection with slightly reduced functionality to allow for better concurrency models.
    #
    # Constructors accept a Hash, another map, or an object whose #each yields key/value pairs.
    # Arrays of pairs and enumerators are supported. Initial entries are inserted in source order.
    # Local maps retain the initial entries for reuse in each scope.
    #
    # `dup` and `clone` create independent storage and coordination while sharing keys and stored values.
    # Value modes and key normalization are preserved without transferring values again.
    # Copies of shareable maps remain shareable unless explicitly cloned with `freeze: false`.
    # Local copies retain the current scope's contents. Other scopes use the original constructor configuration.
    # Lease maps reject copying because resources cannot safely be given independent ownership controls.
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
    # @!method store_if_absent(key)
    #   Read an existing value or construct and store a value for an absent key.
    #   Existing nil and false values count as present when the implementation permits them.
    #   The block runs without holding a map-wide lock. Implementations document their
    #   coordination guarantees, ownership requirements, and optional timeout support.
    #   A later removal or eviction can cause another call to construct a new value.
    #   @param key [BasicObject] The key to look up or store.
    #   @yield Called without arguments when the key is absent.
    #   @yieldreturn [BasicObject] The value to store and return.
    #   @return [BasicObject] The existing or newly constructed value.
    #   @raise [LocalJumpError] If no block is given.
    #   @abstract
    #
    # @!method clear
    #   Remove all entries from the map.
    #   @return [self]
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
    #   Entry consistency and access requirements depend on the implementation. Iteration order is not guaranteed
    #   to match insertion order.
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
    class Map
      include Internal::MarshalSupport::Map
      include Enumerable
      include Internal::Inspect

      # Store a value using the map's assignment operation.
      # Concurrent maps override this method to support timeouts.
      # @param key [BasicObject] the key to store
      # @param value [BasicObject] the value to store
      # @return [BasicObject] `value`
      def store(key, value) = self[key] = value

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

      # Return the number of entries currently in the map.
      # @return [Integer]
      def length = size

      # Return whether an observed value matches using this map's value comparison setting.
      # Values are unwrapped before comparison. Concurrent changes may make the result stale.
      # @param value [BasicObject] the value to find
      # @return [Boolean]
      def value?(value)
        identity = compare_values_by_identity?
        each_value.any? { |stored| identity ? stored.equal?(value) : stored == value }
      end
      alias has_value? value?

      # Return a matching key using this map's value comparison setting, or nil.
      # The first observed match is returned. No insertion order is guaranteed.
      # @param value [BasicObject] the value to find
      # @return [BasicObject, nil]
      def key(value)
        pair = rassoc(value)
        pair&.first
      end

      # Return an observed key/value pair using this map's value comparison setting, or nil.
      # Values are unwrapped before comparison. Concurrent changes may make the result stale.
      # @param value [BasicObject] the value to find
      # @return [Array, nil]
      def rassoc(value)
        identity = compare_values_by_identity?
        each_pair do |key, stored|
          return [key, stored] if identity ? stored.equal?(value) : stored == value
        end
        nil
      end

      # Alias for {#key?}
      def has_key?(...) = key?(...) # rubocop:disable Naming/PredicatePrefix
      alias member?  has_key?
      alias include? has_key?

      # Fetches the values associated with multiple keys, using the same missing-key behavior as Hash#fetch.
      # @yield [key] Called for each missing key.
      # @yieldparam key [BasicObject] The missing key.
      # @yieldreturn [BasicObject] The value to return for the missing key.
      # @param keys [Array<BasicObject>] The keys to look up.
      # @return [Array<BasicObject>] An array of the associated values.
      def fetch_values(*keys, &) = keys.map { fetch(it, &) }

      # @note
      #   Some maps may still accept non-shareable keys or values, but convert them into shareable representations.
      #   This method will still return `true` for such maps.
      #
      # @return [Boolean] Whether the map requires keys to be Ractor-shareable
      def shareable_keys? = false

      # @return [Boolean] Whether the map requires values to be Ractor-shareable
      def shareable_values? = false

      # Creates a new Array containing the map's key-value pairs as two-element arrays.
      # @return [Array<Array(BasicObject, BasicObject)>>] A new Array of `[key, value]` arrays.
      def to_a = each_pair.to_a

      # Creates a new Hash containing the map's entries.
      # Preserves identity comparison for keys, including when a block transforms entries.
      # @yieldparam key [BasicObject] an existing key
      # @yieldparam value [BasicObject] its value
      # @yieldreturn [Array(BasicObject, BasicObject)] the key and value for the new Hash
      # @return [Hash] A new Hash with the original entries, or the pairs returned by the block.
      def to_h(&) = entries_to_hash(each_pair, &)

      # Support implicit Hash conversion using this map's {#to_h} implementation.
      # @return [Hash] A new Hash containing the map's entries.
      def to_hash = to_h

      # Support hash patterns using the same entries and key comparison as {#to_h}.
      # Like Hash, this returns all entries regardless of the requested keys.
      # @param keys [Array, nil] the optional key hint supplied by Ruby's pattern matcher
      # @return [Hash] A new Hash containing the map's entries.
      def deconstruct_keys(keys) = to_h # rubocop:disable Lint/UnusedMethodArgument

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

      # @return [String] String representation of the map, suitable for debugging.
      def to_s = inspect

      # @api private
      def inspect_with(inspector)
        super do
          yield if block_given?
          inspector.breakable
          inspector.group("{", "}") do
            inspector.breakable ""
            inspector.seplist(self, nil, :each_for_inspect) do |key, value|
              inspector.group { inspect_pair(inspector, key, value) }
            end
          end
        end
      end

      protected

      # Convert a public value to its stored representation.
      # @api private
      def wrap_value(value) = value

      # Convert a stored representation to its public value.
      # @api private
      def unwrap_value(value) = value

      private

      def entries_to_hash(entries, &)
        return entries.to_h(&) unless compare_keys_by_identity?
        hash = {}.compare_by_identity
        entries.each do |key, value|
          if block_given?
            pair = Array.try_convert(yield(key, value))
            raise TypeError, "block must return an Array or respond to #to_ary" unless pair
            raise ArgumentError, "block must return a two-element pair" unless pair.size == 2
            key, value = pair
          end
          hash[key] = value
        end
        hash
      end

      def convert_entries(entries)
        return entries if Map === entries
        if entries.respond_to?(:to_hash)
          entries = Hash.try_convert(entries)
          raise TypeError, "entries must be a Hash or respond to #to_hash" unless entries
        end
        return entries if entries.nil? || entries.respond_to?(:each)
        raise TypeError, "entries must yield key/value pairs with #each"
      end

      def each_for_inspect(&)                 = each(&)
      def inspect_pair(inspector, key, value) = inspector.hash_pair(key, value) { inspect_value(inspector, value) }
      def inspect_value(inspector, ...)       = inspector.object(...)
    end
  end
end
