# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Counter
      def initialize(value = 0)
        raise TypeError, "initial value must be an Integer" unless value.is_a?(Integer)
        @counter = Java.type("java.util.concurrent.atomic.AtomicLong").new(value)
        freeze
      end

      def get = @counter.get

      def store(value)
        raise TypeError, "value must be an Integer" unless value.is_a?(Integer)
        @counter.set(value)
        value
      end

      def swap(value)
        raise TypeError, "value must be an Integer" unless value.is_a?(Integer)
        @counter.getAndSet(value)
      end

      def increment(delta = 1)
        raise TypeError, "delta must be an Integer" unless delta.is_a?(Integer)
        @counter.addAndGet(delta)
      end

      def compare_and_set(expected_value, new_value)
        raise TypeError, "expected value must be an Integer" unless expected_value.is_a?(Integer)
        raise TypeError, "replacement value must be an Integer" unless new_value.is_a?(Integer)
        @counter.compareAndSet(expected_value, new_value)
      end

      def decrement(delta = 1) = increment(-delta)

      alias add increment
      alias subtract decrement
      alias value get
      alias value= store
    end
  end
end
