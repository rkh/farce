# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Unsafe
    # @!macro unsafe
    #
    # A {Abstract::Counter counter} that is not thread-safe and cannot be shared between Ractors.
    # @!method initialize(value = 0)
    #   (see Abstract::Counter#initialize)
    #   @return [Counter] new instance of {Counter}.
    class Counter < Abstract::Counter
      include Unshareable::Movable
      include Unshareable::Copyable

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
        @value += Integer(by)
        self
      end
    end
  end
end
