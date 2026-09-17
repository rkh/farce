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

      # @return [String] String representation of the map, suitable for debugging.
      def inspect
        out   = "#<#{self.class.name} {"
        comma = false
        each_for_inspect do |key, value|
          out << ", " if comma
          comma = true
          if Symbol === key
            key = key.to_s.inspect if key.inspect.match?(%r{\A:["$@!]|[%&*+\-/<=>@\]^`|~]\z})
            out << "#{key}:"
          else
            out << "#{key.inspect} =>"
          end
          out << " #{value.inspect}"
        end
        out << "}>"
      end

      # @api private
      # @return [void]
      def pretty_print(pp)
        pp.group(1, "#<#{self.class.name} ", ">") do
          pp.group(1, "{", "}") do
            pp.breakable ""
            pp.seplist(self, nil, :each_for_inspect) do |key, value|
              pp.group { pp.pp_hash_pair(key, value) }
            end
          end
        end
      end

      private

      def each_for_inspect(&) = each(&)
    end
  end
end
