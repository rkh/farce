# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Strict
    # A Ractor-shareable map that keeps shareable entries sorted by key.
    # Mutable string keys become immutable. Other keys and all values must already be Ractor-shareable.
    #
    # @example Keeping direct values in key order
    #   map = Farce::Strict::TreeMap.new(2 => "two".freeze, 1 => "one".freeze)
    #
    #   map.to_a # => [[1, "one"], [2, "two"]]
    class TreeMap < Abstract::TreeMap
      include Shareable::Delegated

      # Values must already be Ractor-shareable.
      # @return [true]
      def shareable_values? = true

      private

      def new_tree_map(...) = Internal::StrictTreeMap.new(...)
      def freeze_backend    = internal_map
    end
  end
end
