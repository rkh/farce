# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract Superclass for maps that retain at most a configured number of entries.
    #
    # Successful individual value reads and writes update the map's eviction policy.
    # Observational operations such as iteration, {#key?}, and {#getkey} do not.
    class BoundedMap < Map
      # @param entries [Hash, Array<Array(BasicObject, BasicObject)>, Map, #each, nil]
      #   Optional initial entries. Entries are stored sequentially and may be evicted.
      # @param max_size [Integer] Maximum number of retained entries.
      # @!macro key_normalization
      # @param compare_by_identity [Boolean] Whether keys and values are compared by identity.
      # @param compare_keys_by_identity [Boolean] Whether keys are compared by identity.
      # @param compare_values_by_identity [Boolean] Whether values are compared by identity.
      def initialize(
        entries = nil,
        max_size:,
        normalize_keys: nil,
        compare_by_identity: false,
        compare_keys_by_identity: compare_by_identity,
        compare_values_by_identity: compare_by_identity
      )
        entries = convert_entries(entries)
        @map    = new_bounded_map(
          max_size:,
          compare_by_identity:,
          compare_keys_by_identity:,
          compare_values_by_identity:,
        )
        @key_locks = new_key_locks(compare_keys_by_identity:)
        restoring  = Internal::KeyNormalizer.restoration?(normalize_keys)
        normalizer = Internal::KeyNormalizer.build(
          normalize_keys,
          shareable: normalize_keys && Internal::KeyNormalizer.shareable_target?(self),
        )
        Internal::KeyNormalizer.install(self, normalizer, Internal::KeyNormalizer::BoundedOperations) unless restoring
        entries&.each { self[_1] = _2 }
        Internal::KeyNormalizer.install(self, normalizer, Internal::KeyNormalizer::BoundedOperations) if restoring
        super()
      end

      # (see Map#[])
      def [](key) = unwrap_value(internal_map[prepare_key(key)])

      # (see Map#[]=)
      def []=(key, value)
        key = prepare_store_key(key)
        with_key_lock(key) { internal_map[key] = wrap_value(value) }
        value
      end

      # Return an existing value, or store the block result for an absent key.
      # Coordinated implementations share one initialization among concurrent
      # callers for equal keys. Unsafe implementations can run competing loaders.
      # The block runs without holding the map's structural lock, so other keys
      # remain accessible. Coordinated assignment waits for initialization.
      # Deletion or clearing can precede a pending initialization's insertion.
      # At zero capacity, coordinated implementations run equal-key loaders
      # sequentially. Each loader validates and transfers its result, but the
      # map retains no value.
      # @param key [BasicObject] The key to retrieve or initialize.
      # @yieldreturn [BasicObject] The value to store.
      # @return [BasicObject] The existing or newly stored value.
      # @raise [LocalJumpError] If no block is given, even when the key exists.
      # @raise [ThreadError] If coordinated initialization recursively accesses its own gate.
      def store_if_absent(key)
        raise LocalJumpError, "no block given" unless block_given?

        map    = internal_map
        found  = true
        stored = map.fetch(prepare_key(key)) { found = false }
        return unwrap_value(stored) if found

        key = prepare_store_key(key)
        with_key_lock(key) do
          stored     = map.fetch(key) do
            wrapped  = wrap_value(yield)
            map[key] = wrapped
            return unwrap_value(wrapped)
          end
          unwrap_value(stored)
        end
      end

      # (see Map#clear)
      def clear
        internal_map.clear
        self
      end

      # (see Map#compare_keys_by_identity?)
      def compare_keys_by_identity? = internal_map.compare_keys_by_identity?

      # (see Map#compare_values_by_identity?)
      def compare_values_by_identity? = internal_map.compare_values_by_identity?

      # (see Map#delete)
      def delete(key) = unwrap_value(internal_map.delete(prepare_key(key)))

      # (see Map#fetch)
      def fetch(*arguments)
        unless arguments.length.between?(1, 2)
          raise ArgumentError, "wrong number of arguments (given #{arguments.length}, expected 1..2)"
        end

        key, default = arguments
        prepared_key = prepare_key(key)
        warn "block supersedes default value argument", uplevel: 1 if block_given? && arguments.length == 2
        value = internal_map.fetch(prepared_key) do
          return yield(key) if block_given?
          return default if arguments.length == 2
          raise KeyError.new("key not found: #{key.inspect}", receiver: self, key: key)
        end
        unwrap_value(value)
      end

      # (see Map#getkey)
      def getkey(key) = internal_map.getkey(prepare_key(key))

      # (see Map#key?)
      def key?(key) = internal_map.key?(prepare_key(key))

      # Return the maximum number of entries retained by the current backing map.
      # @return [Integer]
      def max_size = internal_map.max_size

      # Change the maximum number of retained entries and immediately evict any excess.
      # @param limit [Integer] The new non-negative capacity.
      # @return [Integer] `limit`
      def max_size=(limit)
        internal_map.max_size = limit
      end

      # Remove entries selected by the eviction policy until at most `to` remain.
      # This does not change {#max_size}.
      # @param to [Integer] The non-negative target size.
      # @return [Integer] Number of entries removed.
      def prune(to:) = internal_map.prune(to:)

      # Remove and return the next entry selected by the eviction policy.
      # @return [Array(BasicObject, BasicObject), nil]
      def shift
        pair = internal_map.shift
        [pair.first, unwrap_value(pair.last)] if pair
      end

      # (see Map#size)
      def size = internal_map.size
      alias length size

      # Iterate over a snapshot without updating eviction history.
      # @overload each
      #   @yield [pair] Called once for each entry.
      #   @yieldparam pair [Array<BasicObject>] A two-element `[key, value]` pair.
      #   @return [self]
      # @overload each
      #   @return [Enumerator]
      def each
        return enum_for(__method__) unless block_given?
        internal_map.each { |key, value| yield [key, unwrap_value(value)] }
        self
      end
      alias each_pair each

      # Iterate over a snapshot of stored keys without updating eviction history.
      # @return [self, Enumerator]
      def each_key
        return enum_for(__method__) unless block_given?
        internal_map.each_key { yield it }
        self
      end

      # Iterate over a snapshot of stored values without updating eviction history.
      # @return [self, Enumerator]
      def each_value
        return enum_for(__method__) unless block_given?
        internal_map.each_value { yield unwrap_value(it) }
        self
      end

      # Return a frozen snapshot of stored keys.
      # @return [Array<BasicObject>]
      def keys = each_key.to_a.freeze

      # Return a frozen snapshot of stored values.
      # @return [Array<BasicObject>]
      def values = each_value.to_a.freeze

      # @api private
      # Called by Psych for generating YAML
      def encode_with(coder) = super.tap { it["max_size"] = max_size }

      private

      def indifferent_access_options
        super.merge(max_size:, compare_keys_by_identity: false, compare_values_by_identity: compare_values_by_identity?)
      end

      def each_for_inspect(&)    = each(&)
      def internal_map           = @map
      def prepare_key(key)       = key
      def prepare_store_key(key) = internal_map.prepare_key(prepare_key(key))
      def unwrap_value(value)    = value
      def wrap_value(value)      = value
      def with_key_lock(key, &)  = @key_locks.synchronize(key, &)

      # simplecov:disable
      def new_key_locks(...)
        raise "subclass failed to implement #new_key_locks" unless instance_of?(BoundedMap)
        raise NoMethodError, "Farce::Abstract::BoundedMap should not be instantiated directly. Use a subclass instead."
      end
      # simplecov:enable

      # simplecov:disable
      def new_bounded_map(...)
        raise "subclass failed to implement #new_bounded_map" unless instance_of?(BoundedMap)
        raise NoMethodError, "Farce::Abstract::BoundedMap should not be instantiated directly. Use a subclass instead."
      end
      # simplecov:enable
    end
  end
end
