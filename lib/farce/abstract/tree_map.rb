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
      # @!method first_key
      #   @return [BasicObject] The first key in the map (the smallest key according to the map's ordering).
      #
      # @!method last_key
      #   @return [BasicObject] The last key in the map (the largest key according to the map's ordering).
      #
      # @!method pop
      #   Remove and return the last key-value pair in the map (the largest key according to the map's ordering).
      #   @return [Array(BasicObject, BasicObject)] The last key-value pair in the map.
      #
      # @!method shift
      #   Remove and return the first key-value pair in the map (the smallest key according to the map's ordering).
      #   @return [Array(BasicObject, BasicObject)] The first key-value pair in the map.
      Internal.delegate(self, :@map, :[], :[]=, :delete, :empty?, :fetch, :first_key, :getkey, :key?,
        :last_key, :length, :pop, :shift, :size)

      # @note Subclasses may accept additional, optional arguments (usually keyword arguments) to configure the map.
      # @param entries [Hash, Array<Array(BasicObject, BasicObject)>, Map, #each, nil]
      #   Optional initial entries for the map. Needs to implement #each and yield key-value pairs.
      #   If nil, the map will be empty.
      def initialize(entries = nil)
        if entries.respond_to?(:to_hash)
          @map = new_tree_map(entries)
        else
          @map = new_tree_map
          entries&.each { @map[_1] = _2 }
        end
        super()
      end

      # Remove all entries from the map.
      # @return [self]
      def clear
        @map.clear
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
      # @abstract
      def each(&)
        return enum_for(__method__) unless block_given?
        @map.each(&)
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

      def each_for_inspect(&) = @map.each(&)

      def new_tree_map(...)
        raise "subclass failed to implement #new_tree_map" unless instance_of?(TreeMap)
        raise NoMethodError, "Farce::Abstract::TreeMap should not be instantiated directly. Use a subclass instead."
      end
    end
  end
end
