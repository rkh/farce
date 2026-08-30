# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "java"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # @note This class is not thread-safe.
    class TreeMap < java.util.TreeMap
      def self.new(entries = nil)
        map = super()
        entries&.each { map[_1] = _2 }
        map
      end

      def shift
        value = delete(key = first_key)
        [key, value]
      rescue Java::JavaUtil::NoSuchElementException
        nil
      end

      def first_key
        super
      rescue Java::JavaUtil::NoSuchElementException
        nil
      end
    end
  end
end
