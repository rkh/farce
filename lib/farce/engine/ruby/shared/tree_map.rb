# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # @note This class is not thread-safe.
    class TreeMap < RBTree
      def initialize(entries = nil)
        super()
        entries&.each { self[_1] = _2 }
      end

      def first_key = first&.first
    end
  end
end
