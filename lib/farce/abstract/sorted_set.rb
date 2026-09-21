# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract A set maintained in ascending comparator order.
    # Membership, insertion, and deletion use `<=>`. Two elements occupy the
    # same slot when their comparison returns zero. Elements must be mutually
    # comparable and must not change their ordering while stored. Incompatible
    # elements raise during insertion or lookup.
    class SortedSet < Set
      # Construct a set in ascending comparator order.
      # @overload initialize(enumerable = nil, normalize: nil, compare_by_identity: false, mode: :copy, **options)
      #   @param enumerable [#each, nil] The initial elements, or nil for an empty set.
      #   @param normalize [Symbol, Proc, Hash, Farce::Abstract::Map, nil] The element normalizer.
      #   @param compare_by_identity [Boolean] Must be false. Membership uses <=>.
      #   @param mode [Symbol] The default transfer mode. Only Farce::SortedSet accepts
      #     this option, which defaults to :copy.
      #   @param options [Hash] Additional options for the selected variant.
      #   @option options [Symbol] scope (:ractor) The scope used by Farce::Local::SortedSet.
      #   @yield [element] Optionally transform each initial element before normalization.
      #   @yieldparam element [BasicObject] An element from enumerable.
      #   @yieldreturn [BasicObject] The comparable element to normalize and store.
      #   @return [Farce::Abstract::SortedSet] The new sorted set.
      #   @raise [ArgumentError] If compare_by_identity is true.
      #   @see Farce::Abstract::Set#initialize Additional options for Local variants.
      def initialize(
        enumerable = nil, normalize: nil, compare_by_identity: false, mode: UNDEFINED, **, &transform
      )
        raise ArgumentError, "sorted sets do not support identity comparison" if compare_by_identity
        super(enumerable, normalize:, compare_by_identity: false, mode:, **, &transform)
      end

      # Return whether this set has comparator-equivalent members in the same order.
      # @param other [BasicObject] The object to compare against.
      # @return [Boolean] Whether other is a Farce sorted set with comparator-equivalent members.
      def ==(other)
        return true if equal?(other)
        return false unless other.is_a?(Abstract::SortedSet) && size == other.size
        ordered_keys.zip(other.ordered_keys).all? { comparator_equal?(_1, _2) }
      end

      # Compare canonical ordered members using eql?.
      # @param other [BasicObject] The object to compare against.
      # @return [Boolean] Whether other is a Farce sorted set with eql? ordered members.
      def eql?(other)
        return true if equal?(other)
        other.is_a?(Abstract::SortedSet) && ordered_keys.eql?(other.ordered_keys)
      end

      # Return a hash derived from the canonical ordered members.
      # @return [Integer] The hash code.
      def hash = ordered_keys.hash

      # Remove every comparator-equivalent member yielded by enumerable.
      # @param enumerable [#each] The elements to normalize and remove by comparison.
      # @return [self] The set.
      def subtract(enumerable)
        check_frozen!
        if ordered_compatible?(enumerable)
          enumerable.each_stored { |key, _| @map.delete(key) }
        else
          each_input(enumerable) do |element|
            key = lookup_key(normalize_element(element))
            @map.delete(key) unless MISSING_KEY.equal?(key)
          end
        end
        self
      end

      # Return a same-kind set containing members present by comparator in every input.
      # @param enumerables [Array<#each>] The collections whose comparator-equivalent members must be present.
      # @return [Farce::Abstract::SortedSet] A new sorted set of the same class with the same settings.
      def intersection(*enumerables)
        indexes = enumerables.map { ordered_index(it) }
        dup.filter_stored! { |key, _| indexes.all? { it.key?(key) } }
      end
      alias & intersection

      # Return whether every member has a comparator-equivalent member in other.
      # @param other [Farce::Abstract::Set, ::Set] The set to compare against.
      # @return [Boolean] Whether the comparator-based relation holds.
      # @raise [ArgumentError] If other is not a Farce or Ruby set.
      def subset?(other)
        validate_set_like(other)
        index = ordered_index(other)
        size <= index.size && ordered_keys.all? { index.key?(it) }
      end
      alias <= subset?

      # Return whether this is a proper comparator subset of other.
      # @param other [Farce::Abstract::Set, ::Set] The set to compare against.
      # @return [Boolean] Whether the comparator-based relation holds.
      # @raise [ArgumentError] If other is not a Farce or Ruby set.
      def proper_subset?(other)
        validate_set_like(other)
        index = ordered_index(other)
        size < index.size && ordered_keys.all? { index.key?(it) }
      end
      alias < proper_subset?

      # Return whether every member of other has a comparator-equivalent member here.
      # @param other [Farce::Abstract::Set, ::Set] The set to compare against.
      # @return [Boolean] Whether the comparator-based relation holds.
      # @raise [ArgumentError] If other is not a Farce or Ruby set.
      def superset?(other)
        validate_set_like(other)
        index = ordered_index(other)
        size >= index.size && index.keys.all? { @map.key?(it) }
      end
      alias >= superset?

      # Return whether this is a proper comparator superset of other.
      # @param other [Farce::Abstract::Set, ::Set] The set to compare against.
      # @return [Boolean] Whether the comparator-based relation holds.
      # @raise [ArgumentError] If other is not a Farce or Ruby set.
      def proper_superset?(other)
        validate_set_like(other)
        index = ordered_index(other)
        size > index.size && index.keys.all? { @map.key?(it) }
      end
      alias > proper_superset?

      # Return whether another set has a comparator-equivalent member.
      # @param other [Farce::Abstract::Set, ::Set] The set to compare against.
      # @return [Boolean] Whether the comparator-based relation holds.
      # @raise [ArgumentError] If other is not a Farce or Ruby set.
      def intersect?(other)
        validate_set_like(other)
        index = ordered_index(other)
        left, right = size <= index.size ? [ordered_keys, index] : [index.keys, @map]
        left.any? { right.key?(it) }
      end

      protected

      def ordered_keys = @map.keys
      def ordered?     = true

      private

      def ordered_compatible?(other)
        canonical_compatible?(other) && other.is_a?(Abstract::SortedSet)
      end

      def ordered_index(enumerable)
        index = new_map(nil, compare_keys_by_identity: false, **copy_map_options(self))
        if ordered_compatible?(enumerable)
          enumerable.each_stored { |key, _| index[key] = true }
        else
          each_input(enumerable) do |element|
            key        = lookup_key(normalize_element(element))
            index[key] = true unless MISSING_KEY.equal?(key)
          end
        end
        index
      end

      def comparator_equal?(left, right)
        comparison = left <=> right
        return comparison.zero? if comparison
        raise ArgumentError, "comparison of #{left.class} with #{right.class} failed"
      end

      def identity_membership?(_element) = false
    end
  end
end
