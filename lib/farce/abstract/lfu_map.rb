# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract A bounded map that evicts the least frequently accessed entry.
    # Ties are resolved by least recent access.
    class LFUMap < BoundedMap
      private

      # simplecov:disable
      def new_bounded_map(...)
        raise "subclass failed to implement #new_bounded_map" unless instance_of?(LFUMap)
        raise NoMethodError, "Farce::Abstract::LFUMap should not be instantiated directly. Use a subclass instead."
      end
      # simplecov:enable
    end
  end
end
