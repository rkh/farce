# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "java"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Counter < java.util.concurrent.atomic.AtomicLong
      alias value get

      def initialize(value = 0)
        raise TypeError, "initial value must be an Integer" unless value.is_a?(Integer)
        super
      end

      def store(value)
        raise TypeError, "value must be an Integer" unless value.is_a?(Integer)
        set(value)
        value
      end

      alias value= store

      def swap(value)
        raise TypeError, "value must be an Integer" unless value.is_a?(Integer)
        get_and_set(value)
      end

      def increment(delta = 1)
        raise TypeError, "delta must be an Integer" unless delta.is_a?(Integer)
        add_and_get(delta)
      end

      def compare_and_set(expected_value, new_value)
        raise TypeError, "expected value must be an Integer" unless expected_value.is_a?(Integer)
        raise TypeError, "replacement value must be an Integer" unless new_value.is_a?(Integer)
        super
      end

      def decrement(delta = 1) = increment(-delta)

      alias add increment
      alias subtract decrement
    end
  end
end
