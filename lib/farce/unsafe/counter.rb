# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Unsafe
    # A {Abstract::Counter counter} that is not thread-safe and cannot be shared between Ractors.
    class Counter < Abstract::Counter
      include Unshareable

      # (see Farce::Abstract::Counter#initialize)
      def initialize(value = 0)
        super
        @value = @initial
      end

      # @return [Numeric] The current value of the counter.
      attr_reader :value

      # Reset the counter to its initial value.
      # @return [self] Returns self for chaining.
      def reset
        @value = @initial
        self
      end

      # Increment the counter by the given amount (default is 1).
      # @param [Numeric] by The amount to increment the counter by.
      # @return [self] Returns self for chaining.
      def increment(by = 1)
        @value += number(by)
        self
      end
    end
  end
end
