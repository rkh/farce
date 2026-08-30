# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "java"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Flag
      def initialize(value = false) # rubocop:disable Style/OptionalBooleanParameter
        @reference = java.util.concurrent.atomic.AtomicBoolean.new(validate_boolean(value, "initial value"))
      end

      def value = @reference.get

      def set # rubocop:disable Naming/PredicateMethod
        @reference.set(true)
        true
      end

      def store(value)
        @reference.set(validate_boolean(value, "value"))
        value
      end

      def swap(value) = @reference.get_and_set(validate_boolean(value, "value"))

      def compare_and_set(expected_value, replacement_value)
        expected_value    = validate_boolean(expected_value, "expected value")
        replacement_value = validate_boolean(replacement_value, "replacement value")
        @reference.compare_and_set(expected_value, replacement_value)
      end

      def toggle
        loop do
          current = @reference.get
          replacement = !current
          return replacement if @reference.compare_and_set(current, replacement)
        end
      end

      alias get value
      alias value= store

      private

      def validate_boolean(value, name)
        return value if value.equal?(true) || value.equal?(false)
        raise ArgumentError, "#{name} must be true or false"
      end
    end
  end
end
