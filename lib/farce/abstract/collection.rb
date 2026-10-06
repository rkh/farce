# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract Superclass for a collection of elements.
    #
    # Subclasses define traversal, comparison, and insertion rules.
    # They may accept additional optional parameters for the methods below.
    #
    # Notable subclasses include {Vector}, {Set}, and {SortedSet}.
    #
    # @!method each
    #   Iterate over the elements currently present.
    #   @yield [element] Visit each element. Returns an Enumerator without a block.
    #   @yieldparam element [BasicObject] The current element.
    #   @yieldreturn [void] The result is ignored.
    #   @return [self, Enumerator] Self, or a sized Enumerator without a block.
    #   @abstract
    #
    # @!method size
    #   Return the number of elements currently present.
    #   @return [Integer] The number of elements.
    #   @abstract
    #
    # @!method to_a
    #   Return the observed elements in a new Array.
    #   @return [Array<BasicObject>] The observed elements.
    #   @abstract
    #
    # @!method clear
    #   Remove all elements and return self.
    #   @return [self] The collection.
    #   @abstract
    #
    # @!method include?(element)
    #   Return whether an element is present using the collection's membership rules.
    #   @param element [BasicObject] The element to look up.
    #   @return [Boolean] Whether the element is present.
    #   @abstract
    #
    # @!method member?(element)
    #   Return whether an element is present, as with {#include?}.
    #   @param element [BasicObject] The element to look up.
    #   @return [Boolean] Whether the element is present.
    #   @see #include?
    #   @abstract
    #
    # @!method compare_by_identity?
    #   Return whether elements are compared by object identity.
    #   @return [Boolean] Whether identity comparison is enabled.
    #   @abstract
    #
    # @!method select
    #   Return a collection of the same kind containing elements accepted by the block.
    #   @yield [element] Test each element. Returns an Enumerator without a block.
    #   @yieldparam element [BasicObject] The current element.
    #   @yieldreturn [BasicObject] A truthy value to retain the element.
    #   @return [Farce::Abstract::Collection, Enumerator] A new collection, or an Enumerator without a block.
    #   @abstract
    #
    # @!method filter
    #   Return elements accepted by the block, as with {#select}.
    #   @yield [element] Test each element. Returns an Enumerator without a block.
    #   @yieldparam element [BasicObject] The current element.
    #   @yieldreturn [BasicObject] A truthy value to retain the element.
    #   @return [Farce::Abstract::Collection, Enumerator] A new collection of the same kind, or an Enumerator.
    #   @see #select
    #   @abstract
    #
    # @!method reject
    #   Return a collection of the same kind excluding elements accepted by the block.
    #   @yield [element] Test each element. Returns an Enumerator without a block.
    #   @yieldparam element [BasicObject] The current element.
    #   @yieldreturn [BasicObject] A truthy value to exclude the element.
    #   @return [Farce::Abstract::Collection, Enumerator] A new collection, or an Enumerator without a block.
    #   @abstract
    #
    # @!method <<(element)
    #   Add an element using the collection's insertion rules and return self.
    #   @param element [BasicObject] The element to add.
    #   @return [self] The collection.
    #   @abstract
    class Collection
      include Enumerable
      include Internal::Copyable
      include Internal::Inspect

      # @overload [](*elements, **options)
      #   Construct a collection from the arguments.
      #   @param elements [Array<BasicObject>] The initial elements.
      #   @param **options [Hash] Additional options passed to the constructor.
      #   @return [Farce::Abstract::Collection] A new instance of the receiving class.
      def self.[](*elements, **) = new(elements, **)

      # Return the number of elements currently present.
      # @return [Integer] The collection's size.
      def length = size

      # Return whether no elements are present.
      # @return [Boolean] Whether the collection is empty.
      def empty? = size.zero?

      # Count all elements, matching elements, or elements accepted by a block.
      # Without an argument or block, read the size without traversing elements.
      # @param item [BasicObject] The value to count. Omit to count all elements or use the block.
      # @yield [element] Select elements to count when item is omitted.
      # @yieldparam element [BasicObject] The current element.
      # @yieldreturn [BasicObject] A truthy value to count the element.
      # @return [Integer] The number of matching elements.
      def count(item = UNDEFINED)
        return size if item.equal?(UNDEFINED) && !block_given?

        if item.equal?(UNDEFINED)
          super() { yield it }
        else
          warn("given block not used") if block_given?
          super(item, &nil)
        end
      end

      # Join the elements through Array#join.
      # @param separator [String, nil] The separator. Nil uses Array's default separator.
      # @return [String] The joined elements.
      def join(separator = nil) = to_a.join(separator)

      # @return [String] The class name and observed elements, suitable for debugging.
      def to_s = inspect

      # @api private
      def inspect_with(inspector)
        super do
          yield if block_given?
          inspector.breakable
          inspector.group("[", "]") do
            inspector.breakable ""
            inspector.seplist(self, nil, :each_for_inspect) do |value|
              inspector.group { inspect_value(inspector, value) }
            end
          end
        end
      end

      private

      def each_for_inspect(&)           = each(&)
      def inspect_value(inspector, ...) = inspector.object(...)
    end
  end
end
