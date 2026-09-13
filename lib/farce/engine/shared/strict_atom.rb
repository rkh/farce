# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Preserve the unrestricted Atom backend for unshared internals.
    class StrictAtom < Atom
      def initialize(value = nil, **)
        super(check_value(value), **)
      end

      def store(value, **, &) = super(check_value(value), **, &)
      def swap(value, **, &) = super(check_value(value), **, &)
      def wait_until_changed(expected, **, &) = super(check_value(expected), **, &)

      def value=(value)
        store(value)
      end

      def compare_and_set(expected, value, **)
        super(check_value(expected), check_value(value), **)
      end

      def store_if_absent(**)
        raise LocalJumpError, "no block given" unless block_given?
        super { check_value(yield) }
      end

      def update(**)
        raise LocalJumpError, "no block given" unless block_given?
        super { |value| check_value(yield(value)) }
      end

      def upsert(initial, **)
        raise LocalJumpError, "no block given" unless block_given?
        super(check_value(initial), **) { |value| check_value(yield(value)) }
      end

      private

      def check_value(value)
        return value if Ractor.shareable?(value)
        raise Ractor::IsolationError, "value must be Ractor-shareable"
      end
    end
  end
end
