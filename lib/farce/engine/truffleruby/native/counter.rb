# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Counter < Numeric
      def initialize(value = 0)
        raise TypeError, "initial value must be an Integer" unless value.is_a?(Integer)
        @reference = TruffleRuby::AtomicReference.new(value)
        super()
        freeze
      end

      def get = @reference.get

      def store(value)
        raise TypeError, "value must be an Integer" unless value.is_a?(Integer)
        @reference.set(value)
        value
      end

      def swap(value)
        raise TypeError, "value must be an Integer" unless value.is_a?(Integer)
        @reference.get_and_set(value)
      end

      def compare_and_set(expected_value, new_value)
        raise TypeError, "expected value must be an Integer" unless expected_value.is_a?(Integer)
        raise TypeError, "replacement value must be an Integer" unless new_value.is_a?(Integer)
        @reference.compare_and_set(expected_value, new_value)
      end

      def add(delta = 1)
        raise TypeError, "delta must be an Integer" unless delta.is_a?(Integer)
        change(delta)
      end

      def subtract(delta = 1)
        raise TypeError, "delta must be an Integer" unless delta.is_a?(Integer)
        change(-delta)
      end

      def increment(delta = 1)
        change(Integer(delta))
        self
      end

      def decrement(delta = 1)
        change(-Integer(delta))
        self
      end

      alias value get
      alias value= store

      private

      def change(delta)
        loop do
          old_value = @reference.get
          new_value = old_value + delta
          return new_value if @reference.compare_and_set(old_value, new_value)
        end
      end

      def initialize_copy(other)
        @reference = TruffleRuby::AtomicReference.new(other.value)
      end
    end
  end
end
