# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Unshared
    # A thread-safe map that keeps entries sorted by key within one Ractor.
    # Mutable string keys become immutable. Values are stored directly and may be mutable.
    #
    # @example Keeping mutable values in key order
    #   value = []
    #   map = Farce::Unshared::TreeMap.new(2 => value, 1 => [])
    #
    #   map[2].equal?(value) # => true
    class TreeMap < Abstract::TreeMap
      include Unshareable

      private def new_tree_map(...) = Internal::TreeMap.new(...)
    end
  end
end
