# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Vector < UnsharedVector
      def initialize(source = nil, **)
        source.each { check_value(it) } if source.is_a?(Array)
        super
      end

      def []=(index, value)
        check_value(value)
        super
      end

      def store(index, value, **)
        check_value(value)
        super
      end

      def push(value, **)
        check_value(value)
        super
      end

      def swap(index, replacement, **)
        check_value(replacement)
        super
      end

      def compare_and_set(index, expected, replacement, **)
        check_value(replacement)
        super
      end

      def store_if_absent(index, **)
        raise LocalJumpError, "no block given" unless block_given?
        super { check_value(yield) }
      end

      def update(index, **)
        raise LocalJumpError, "no block given" unless block_given?
        super { check_value(yield(it)) }
      end

      def upsert(index, initial, **)
        raise LocalJumpError, "no block given" unless block_given?
        check_value(initial)
        super { check_value(yield(it)) }
      end

      private

      def check_value(value)
        raise Ractor::IsolationError, "value is not Ractor-shareable" unless Ractor.shareable?(value)
        value
      end
    end
  end
end
