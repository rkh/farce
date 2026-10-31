# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Strict
    # A weak cache that allows reusing previously generated values without holding strong references to them.
    # Only shareable keys and values can be used.
    #
    # @example
    #   cache = Farce::Strict::WeakCache.new
    #   value = cache.store_if_absent(:key) { ExpensiveClass.new.freeze }
    class WeakCache
      include Shareable::Delegated
      include Internal::Inspect

      # Creates a new WeakCache instance if it outperforms {Strict::WeakValueMap} on the current platform.
      # Otherwise it creates a standard WeakValueMap instance.
      # @return [WeakCache, Strict::WeakValueMap] The created cache instance.
      def self.create(...) = Internal.native_weak_maps? ? Strict::WeakValueMap.new(...) : WeakCache.new(...)

      # @param initial_mapping [Hash, Farce::Abstract::Map, #each, nil]
      #   The entries to store initially. Each iteration must yield a key-value pair.
      #   Nil creates an empty map.
      # @param compare_by_identity [Boolean]
      #   Whether keys use object identity instead of `hash` and `eql?`.
      def initialize(initial_mapping = nil, compare_by_identity: false)
        @map = Strict::WeakValueMap.new(initial_mapping, compare_keys_by_identity: compare_by_identity)
        initialize_cache
        super()
      end

      # @api private
      def marshal_dump = [1, @map]

      # @api private
      def marshal_load(data)
        @map, = Internal::MarshalSupport.payload(data, 1)
        initialize_cache
        publish_shareable
      end

      # Retrieves or stores a value for the given key.
      # The block is called to generate the value if the key is absent.
      # Concurrent calls for the same key reuse the generated value.
      # Once that value is collected, a later call generates it again.
      #
      # @param key [BasicObject] The key to look up.
      # @yield Called without arguments when the key is absent.
      # @yieldreturn [BasicObject] The value to store and return.
      # @return [BasicObject] The associated value.
      def store_if_absent(key, &)
        raise LocalJumpError, "no block given" unless block_given?
        @cache.store_if_absent(key, &)
      end

      alias compute_if_absent store_if_absent

      # Store a value only when the key is absent.
      # Existing nil and false values count as present.
      # @param key [BasicObject] The key to look up or store.
      # @param value [BasicObject] The value to store if the key is absent.
      # @return [BasicObject, nil] The existing value, or nil when a value was inserted.
      def put_if_absent(key, value)
        inserted = false
        previous = store_if_absent(key) do
          inserted = true
          value
        end
        inserted ? nil : previous
      end

      # Look up a value without generating it.
      # @param key [BasicObject] The key to look up.
      # @return [BasicObject, nil] The associated value, or nil if the key is absent.
      def [](key) = @cache.fetch(key) { nil } # rubocop:disable Style/RedundantFetchBlock

      # Return a lookup key and its associated value if present.
      # @param key [BasicObject] The key to look up.
      # @return [Array(BasicObject, BasicObject), nil] The pair `[key, value]`, or nil if the key is absent.
      def assoc(key)
        value = fetch(key) { return nil }
        [key, value]
      end

      # Return whether a live entry exists, including entries with nil or false values.
      # @param key [BasicObject] The key to look up.
      # @return [Boolean]
      def key?(key)
        @cache.fetch(key) { return false }
        true
      end

      alias has_key? key?
      alias include? key?
      alias member?  key?

      # Look up a value in nested maps or arrays.
      # @param key [BasicObject] The key to look up.
      # @param rest [Array<BasicObject>] Additional keys or indices for the nested value.
      # @return [BasicObject, nil] The nested value, or nil if an intermediate value is absent or nil.
      def dig(key, *rest)
        value = self[key]
        return value if rest.empty? || value.nil?
        value.dig(*rest)
      end

      # Return the stored key matching a lookup key.
      # @param key [BasicObject] The key to look up.
      # @return [BasicObject, nil] The stored key, or nil if the key is absent.
      def getkey(key) = @map.getkey(key)

      # Fetch the value associated with a key, using the same missing-key behavior as Hash#fetch.
      # If both a default and a block are provided, the block takes precedence.
      #
      # @overload fetch(key)
      #   @param key [BasicObject] The key to look up.
      #   @return [BasicObject] The associated value.
      #   @raise [KeyError] If the key is absent.
      #
      # @overload fetch(key, default)
      #   @param key [BasicObject] The key to look up.
      #   @param default [BasicObject] The value to return if the key is absent.
      #   @return [BasicObject] The associated value or `default`.
      #
      # @overload fetch(key)
      #   @param key [BasicObject] The key to look up.
      #   @yield [key] Called if the key is absent.
      #   @yieldparam key [BasicObject] The missing key.
      #   @yieldreturn [BasicObject] The value to return.
      #   @return [BasicObject] The associated value or the block result.
      def fetch(*arguments)
        unless arguments.length.between?(1, 2)
          raise ArgumentError, "wrong number of arguments (given #{arguments.length}, expected 1..2)"
        end

        key, default = arguments
        warn "block supersedes default value argument", uplevel: 1 if block_given? && arguments.length == 2
        @cache.fetch(key) do
          return yield(key) if block_given?
          return default if arguments.length == 2
          raise KeyError.new("key not found: #{key.inspect}", receiver: self, key: key)
        end
      end

      # Fetch values in the requested order, using {#fetch} for missing keys.
      # @param keys [Array<BasicObject>] The keys to look up.
      # @yield [key] Called for each missing key.
      # @yieldparam key [BasicObject] The missing key.
      # @yieldreturn [BasicObject] The fallback value, which is not stored.
      # @return [Array<BasicObject>] The associated values or block results.
      def fetch_values(*keys, &) = keys.map { fetch(it, &) }

      # Look up values in the requested order, returning nil for missing keys.
      # @param keys [Array<BasicObject>] The keys to look up.
      # @return [Array<BasicObject>] The associated values, with nil for missing keys.
      def values_at(*keys) = keys.map { self[it] }

      # @return [Boolean] Whether keys are compared by identity instead of `hash` and `eql?`.
      def compare_keys_by_identity? = @map.compare_keys_by_identity?

      # (see #compare_keys_by_identity?)
      def compare_by_identity? = compare_keys_by_identity?

      # @return [Boolean] Whether keys must be Ractor-shareable, including copied mutable strings.
      def shareable_keys? = true

      # @return [Boolean] Whether values must be Ractor-shareable.
      def shareable_values? = true

      # @return [Boolean] Whether keys are referenced weakly.
      def weak_keys? = false

      # @return [Boolean] Whether values are referenced weakly.
      def weak_values? = true

      # @api private
      def inspect_with(inspector)
        super do
          yield if block_given?
          inspector.breakable
          inspector.group("{", "}") do
            inspector.breakable ""
            inspector.seplist(@map, nil, :each) do |key, value|
              inspector.group { inspector.hash_pair(key, value) }
            end
          end
        end
      end

      alias to_s inspect

      private

      def initialize_cache = @cache = Internal.native_weak_maps? ? @map : Internal::WeakCacheMirror.new(@map)
      def freeze_backend   = @map
    end
  end
end
