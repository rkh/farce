# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce"
require "active_support"
require "active_support/core_ext"

module Farce
  module Abstract
    class Set
      # Deeply copy elements into a set of the same kind with the same settings.
      # Copied elements pass through the set's normal storage rules.
      # Weak results do not keep copied heap elements alive by themselves.
      # @return [Farce::Abstract::Set]
      def deep_dup = map_canonical(&:deep_dup)

      # Return a same-kind set without blank elements.
      # @return [Farce::Abstract::Set]
      def compact_blank = reject(&:blank?)

      # Remove blank elements and return self.
      # @return [self]
      def compact_blank! = delete_if(&:blank?)

      # Return a same-kind set with elements added. Array arguments are flattened by one level.
      # @param elements [Array<BasicObject>] Elements or Arrays of elements to add.
      # @return [Farce::Abstract::Set] A new set of the same class with the same settings.
      def including(*elements) = union(elements.flatten(1))

      # Return a same-kind set without the supplied elements. Array arguments are flattened by one level.
      # @param elements [Array<BasicObject>] Elements or Arrays of elements to remove.
      # @return [Farce::Abstract::Set] A new set of the same class with the same settings.
      def excluding(*elements) = difference(elements.flatten(1))
      alias without excluding

      # Convert the elements through ActiveSupport's Array JSON conversion.
      # @overload as_json(options = nil)
      #   @param options [Hash, nil] Options passed to each element's JSON conversion.
      #   @return [Array] The JSON-compatible values.
      def as_json(...) = to_a.as_json(...)

      # Return the elements' ActiveSupport parameter representation.
      # @return [String]
      def to_param = to_a.to_param

      # Encode the elements as repeated query parameters under a key.
      # @param key [String, Symbol] The query parameter name.
      # @return [String] The encoded query string.
      def to_query(key) = to_a.to_query(key)
    end
  end
end
