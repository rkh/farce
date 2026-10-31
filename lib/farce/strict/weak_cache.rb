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
    #   value = cache.get(:key) { ExpensiveClass.new.freeze }
    class WeakCache
      include Shareable::Delegated
      include Internal::Inspect

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
      def get(key, &)
        raise LocalJumpError, "no block given" unless block_given?
        @cache.store_if_absent(key, &)
      end

      alias store_if_absent get

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

      # @return [Boolean] Whether keys are compared by identity instead of `hash` and `eql?`.
      def compare_by_identity? = @map.compare_keys_by_identity?

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

      private

      def initialize_cache = @cache = Internal.native_weak_maps? ? @map : Internal::WeakCacheMirror.new(@map)
      def freeze_backend   = @map
    end
  end
end
