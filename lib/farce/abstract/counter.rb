# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # A counter is a stateful, numeric object.
    #
    # @!method value
    #   @abstract
    #   @return [Numeric] The current value of the counter.
    #
    # @!method increment(by = 1)
    #   @abstract
    #   Increment the counter by the given amount (default is 1).
    #   @param [Numeric] by The amount to increment the counter by.
    #   @return [self] Returns self for chaining.
    #
    # @!method reset
    #   @abstract
    #   Reset the counter to its initial value.
    #   @return [self] Returns self for chaining.
    # @abstract
    class Counter < Numeric
      include Value

      KNOWN_NUMERIC_CLASSES = Set[Integer, Float, Complex, Rational].compare_by_identity.freeze
      private_constant :KNOWN_NUMERIC_CLASSES

      # @param [Numeric] value The initial value of the counter.
      attr_reader :initial

      # @param [Numeric] value The initial value of the counter.
      def initialize(value = 0)
        @initial = number(value)
        super()
      end

      # @return [true, false] Returns true if the current value is NaN.
      def nan?
        value = self.value
        value.respond_to?(:nan?) && value.nan?
      end

      # @return [String] Returns a string representation of the counter.
      def inspect = "#<#{self.class.name} #{value.inspect}>"

      # (see #increment)
      def add(...) = increment(...)

      # Decrement the counter by the given amount (default is 1).
      # @param [Numeric] by The amount to decrement the counter by.
      # @return [self] Returns self for chaining.
      def decrement(by = 1) = increment(-by)
      alias subtract decrement
      alias remove   decrement

      methods  = Numeric.public_instance_methods(false) - Object.public_instance_methods - [:singleton_method_added]
      methods += %i[+ - / * ** <=> coerce rationalize to_i to_int to_f to_c to_r to_s]
      methods.uniq!
      Internal.delegate(self, :value, *methods)

      private

      # Forwards any missing methods to the current value of the counter.
      def method_missing(...) = value.public_send(...)
      def respond_to_missing?(method, ...) = value.respond_to?(method)

      def number(value)
        return value if KNOWN_NUMERIC_CLASSES.include?(value.class)
        value = value.unwrap if value.is_a?(Value)
        return 0 if value.nil?

        value, = (initial || 0).coerce(value)
        value  = value.freeze unless value.frozen?
        value  = Float(value) unless Ractor.shareable?(value)
        value
      end
    end
  end
end
