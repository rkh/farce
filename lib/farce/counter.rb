# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # Ractor-shareable, atomic counter.
  # This is a stateful, numeric object.
  #
  # Values are converted to Integers. On CRuby, the stored value and arithmetic
  # deltas must fit in a signed 64-bit integer; overflow raises RangeError without
  # changing the stored value. Conditional-operation bounds may be wider, but a
  # resulting stored value must still fit.
  #
  # On CRuby, subclasses must not add Ruby instance variables.
  #
  # @!method initial
  #   @return [Integer] The initial value retained by reset and copies.
  #
  # @!method value
  #   @return [Integer] The current value of the counter.
  #
  # @!method increment(by = 1)
  #   Increment the counter by the given amount (default is 1).
  #   @param [Numeric, String, #to_int] by The amount, converted to an Integer.
  #   @return [self] Returns self for chaining.
  #
  # @!method decrement(by = 1)
  #   Decrement the counter by the given amount (default is 1).
  #   @param [Numeric, String, #to_int] by The amount, converted to an Integer.
  #   @return [self] Returns self for chaining.
  #
  # @example Cross-Ractor counting
  #   counter = Farce::Counter.new
  #   counter.value # => 0
  #
  #   # Increase the counter by 1
  #   counter.increment
  #   counter.value # => 1
  #
  #   # Increase the counter by 5 on another Ractor
  #   Ractor.new(counter) { it.add(5) }
  #
  #   # Give the other ractor time to run
  #   sleep 0.1
  #
  #   counter.value # => 6
  #
  # @example Counter as a numeric value
  #   counter = Farce::Counter.new(10.0)
  #   counter.to_i  # => 10
  #   counter + 5   # => 15
  #   2.5 * counter # => 25.0
  #
  #   require "active_support/all"
  #   counter.minutes.to_i # => 600
  class Counter < Internal::Counter
    include Abstract::Counter
    include Shareable::Native

    # @param [Numeric, String, #to_int] value The initial value, converted to an Integer.
    def initialize(value = 0)
      raise FrozenError.new("can't initialize a frozen counter", receiver: self) if frozen?
      super(Integer(value))
    end

    alias subtract decrement
    alias remove   decrement
  end
end
