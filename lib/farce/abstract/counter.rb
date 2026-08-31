# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # A counter is a stateful Integer that can be increased and decreased.
    #
    # @!method value
    #   @abstract
    #   @return [Integer] The current value of the counter.
    #
    # @!method increment(by = 1)
    #   @abstract
    #   Increment the counter by the given amount (default is 1).
    #   @param [Integer] by The amount to increment the counter by.
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

      # @return [Integer] initial The initial value of the counter.
      attr_reader :initial

      # @param [Numeric, String, #to_int] value The initial value of the counter. Will be converted to an Integer.
      def initialize(value = 0)
        prepare
        @initial = Integer(value)
        reset
        super()
      end

      # @overload add(by = 1)
      #   (see #increment)
      def add(...) = increment(...)

      # Decrement the counter by the given amount (default is 1).
      # @param [Numeric] by The amount to decrement the counter by.
      # @return [self] Returns self for chaining.
      def decrement(by = 1) = increment(-by)
      alias subtract decrement
      alias remove   decrement

      methods  = Integer.public_instance_methods - Object.public_instance_methods - [:singleton_method_added]
      methods += %i[+ - / * ** <=> coerce rationalize to_i to_int to_f to_c to_r to_s]
      methods.uniq!
      Internal.delegate(self, :value, *methods)

      # @return [String] Returns a string representation of the counter.
      def inspect = "#<#{self.class.name} #{value.inspect}>"

      # @api private
      # @return [void]
      def pretty_print(pp) = pp.group(1, "#<#{self.class.name} ", ">") { pp.pp(value) }

      private

      # Forwards any missing methods to the current value of the counter.
      def method_missing(...) = value.public_send(...)
      def respond_to_missing?(method, ...) = value.respond_to?(method)
      def prepare = nil
    end
  end
end
