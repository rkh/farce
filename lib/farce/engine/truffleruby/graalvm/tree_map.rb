# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # @note This class is not thread-safe.
    class TreeMap
      NoSuchElementException = Java.type("java.util.NoSuchElementException")
      private_constant :NoSuchElementException

      def initialize(entries = nil)
        @map = Java.type("java.util.TreeMap").new
        entries&.each { self[_1] = _2 }
      end

      def first_key
        @map.firstKey
      rescue NoSuchElementException
        nil
      end

      def shift
        value = delete(key = first_key)
        [key, value]
      rescue NoSuchElementException
        nil
      end

      Internal.delegate(self, :@map, :[], :[]=, :delete, :empty?, :size)
    end
  end
end
