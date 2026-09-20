# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract Superclass for all tree map implementations.
    #
    # You can think of a tree map as a sorted hash (sorted by key).
    # Under the hood, tree maps are implemented as a balanced binary search tree.
    #
    # This means lookups, insertions, and deletions are O(log n) operations (vs O(1) for a hash map).
    # This is much slower than a hash map, but much faster than ad hoc sorting of the map.
    class TreeMap < Map
      include DuplicableMap

      # @note Subclasses may accept additional, optional arguments (usually keyword arguments) to configure the map.
      # @param entries [Hash, Array<Array(BasicObject, BasicObject)>, Map, #each, nil]
      #   Optional initial entries for the map. Needs to implement #each and yield key-value pairs.
      #   If nil, the map will be empty.
      # @!macro key_normalization
      def initialize(entries = nil, normalize_keys: nil, **keyword_entries)
        unless keyword_entries.empty?
          raise ArgumentError, "entries given as both positional and keyword arguments" unless entries.nil?
          entries = keyword_entries
        end
        entries = convert_entries(entries)
        @map       = new_tree_map
        @key_locks = new_key_locks
        restoring  = Internal::KeyNormalizer.restoration?(normalize_keys)
        normalizer = Internal::KeyNormalizer.build(
          normalize_keys,
          shareable: normalize_keys && Internal::KeyNormalizer.shareable_target?(self),
        )
        Internal::KeyNormalizer.install(self, normalizer, Internal::KeyNormalizer::TreeOperations) unless restoring
        entries&.each { self[_1] = _2 }
        Internal::KeyNormalizer.install(self, normalizer, Internal::KeyNormalizer::TreeOperations) if restoring
        super()
      end

      # (see Map#[])
      def [](key) = unwrap_value(internal_map[prepare_key(key)])

      # (see Map#[]=)
      def []=(key, value)
        key = internal_map.prepare_key(prepare_key(key))
        with_key_lock(key) { internal_map[key] = wrap_value(value) }
        value
      end

      # Return an existing value, or store the block result for an absent key.
      # Concurrent callers for equally ordered keys share one initialization.
      # The block runs without holding the map's structural lock. Other keys
      # remain accessible. Assigning the same key waits for initialization.
      # Deletion or clearing can precede a pending initialization's insertion.
      # Unsafe maps require callers to provide their own synchronization.
      # @param key [BasicObject] The key to retrieve or initialize.
      # @yieldreturn [BasicObject] The value to store.
      # @return [BasicObject] The existing or newly stored value.
      # @raise [LocalJumpError] If no block is given, even when the key exists.
      # @raise [ThreadError] If initialization recursively accesses its own gate.
      def store_if_absent(key)
        raise LocalJumpError, "no block given" unless block_given?

        map      = internal_map
        key      = map.prepare_key(prepare_key(key))
        found    = true
        existing = map.fetch(key) { found = false }
        return unwrap_value(existing) if found

        with_key_lock(key) do
          stored     = map.fetch(key) do
            value    = yield
            wrapped  = wrap_value(value)
            map[key] = wrapped
            return unwrap_value(wrapped)
          end
          unwrap_value(stored)
        end
      end

      # (see Map#delete)
      def delete(key) = unwrap_value(internal_map.delete(prepare_key(key)))

      # (see Map#empty?)
      def empty? = internal_map.empty?

      # (see Map#fetch)
      def fetch(*arguments)
        unless arguments.length.between?(1, 2)
          raise ArgumentError, "wrong number of arguments (given #{arguments.length}, expected 1..2)"
        end

        key, default = arguments
        key = prepare_key(key)
        warn "block supersedes default value argument", uplevel: 1 if block_given? && arguments.length == 2
        value = internal_map.fetch(key) do
          return yield(key) if block_given?
          return default if arguments.length == 2
          raise KeyError.new("key not found: #{key.inspect}", receiver: self, key: key)
        end
        unwrap_value(value)
      end

      # Return the smallest key according to the map's ordering.
      # @return [BasicObject, nil] The first key, or nil if the map is empty.
      def first_key = internal_map.first_key

      # (see Map#getkey)
      def getkey(key) = internal_map.getkey(prepare_key(key))

      # (see Map#key?)
      def key?(key) = internal_map.key?(prepare_key(key))

      # Return the largest key according to the map's ordering.
      # @return [BasicObject, nil] The last key, or nil if the map is empty.
      def last_key = internal_map.last_key

      # (see Map#size)
      def length = internal_map.length

      # Remove and return the entry with the largest key according to the map's ordering.
      # @return [Array(BasicObject, BasicObject), nil] The last key-value pair, or nil if the map is empty.
      def pop
        pair = internal_map.pop
        [pair.first, unwrap_value(pair.last)] if pair
      end

      # Remove and return the entry with the smallest key according to the map's ordering.
      # @return [Array(BasicObject, BasicObject), nil] The first key-value pair, or nil if the map is empty.
      def shift
        pair = internal_map.shift
        [pair.first, unwrap_value(pair.last)] if pair
      end

      # (see Map#size)
      def size = internal_map.size

      # Remove all entries from the map.
      # @return [self]
      def clear
        internal_map.clear
        self
      end

      # Iterate over the map's key-value pairs.
      # Order is guaranteed to be from smallest to largest key according.
      #
      # @overload each
      #   @yield [pair] Called once for each entry.
      #   @yieldparam pair [Array<BasicObject>] A two-element `[key, value]` pair.
      #   @return [self]
      # @overload each
      #   @return [Enumerator] An enumerator over two-element `[key, value]` pairs.
      def each
        return enum_for(__method__) unless block_given?
        internal_map.each { |key, value| yield [key, unwrap_value(value)] }
        self
      end

      alias each_pair each

      # Iterate over the keys currently stored in the map.
      # Keys are yielded from smallest to largest.
      #
      # @overload each_key
      #   @yield [key] Called once for each stored key.
      #   @yieldparam key [BasicObject] A stored key.
      #   @return [self]
      # @overload each_key
      #   @return [Enumerator] An enumerator over the stored keys.
      def each_key
        return enum_for(__method__) unless block_given?
        each { |key, _| yield key }
        self
      end

      # Iterate over the values currently stored in the map.
      # Values are yielded in the order of their corresponding keys (from smallest to largest).
      #
      # @overload each_value
      #   @yield [value] Called once for each stored value.
      #   @yieldparam value [BasicObject] A stored value.
      #   @return [self]
      # @overload each_value
      #   @return [Enumerator] An enumerator over the stored values.
      def each_value
        return enum_for(__method__) unless block_given?
        each { |_, value| yield value }
        self
      end

      # Return the keys currently stored in the map.
      # The result is frozen and ordered from smallest to largest key.
      # @return [Array<BasicObject>] The keys currently stored in the map, in order from smallest to largest.
      def keys = each_key.to_a.freeze

      # Return the values currently stored in the map.
      # The result is frozen and ordered according to the order of their corresponding keys (from smallest to largest).
      # @return [Array<BasicObject>] The values currently stored in the map.
      def values = each_value.to_a.freeze

      # TreeMap keys always have to be Ractor-shareable.
      # Mutable strings are accepted however and will be converted to an immutable string.
      # @return [true]
      def shareable_keys? = true

      # TreeMap keys are compared by their ordering, never by identity.
      # @return [false]
      def compare_keys_by_identity? = false

      # TreeMap values are compared by equality, never by identity.
      # @return [false]
      def compare_values_by_identity? = false

      private

      def copy_map_backend(source)
        copied = source.class.new
        source.each { |key, value| copied[key] = value }
        copied
      end

      def install_copied_map(map)
        super
        @key_locks = new_key_locks
      end

      def each_for_inspect(&) = each(&)

      def prepare_key(key)
        return key if String === key || Ractor.shareable?(key)
        raise Ractor::IsolationError, "key must be Ractor-shareable"
      end

      def unwrap_value(value)   = value
      def wrap_value(value)     = value
      def new_key_locks         = Internal::OrderedKeyLockMap.new
      def with_key_lock(key, &) = @key_locks.synchronize(key, &)

      # simplecov:disable
      def new_tree_map(...)
        raise "subclass failed to implement #new_tree_map" unless instance_of?(TreeMap)
        raise NoMethodError, "Farce::Abstract::TreeMap should not be instantiated directly. Use a subclass instead."
      end
      # simplecov:enable

      private def internal_map = @map
    end
  end
end
