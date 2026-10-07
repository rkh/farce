# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract A bounded map that evicts the least recently accessed entry.
    class LRUMap < BoundedMap
      private

      # @api private
      def marshal_entries
        map = marshal_map.dup
        Array.new(map.size) { map.shift }
      end

      # simplecov:disable
      def new_bounded_map(...)
        raise "subclass failed to implement #new_bounded_map" unless instance_of?(LRUMap)
        raise NoMethodError, "Farce::Abstract::LRUMap should not be instantiated directly. Use a subclass instead."
      end
      # simplecov:enable
    end
  end
end
