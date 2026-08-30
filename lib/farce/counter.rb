# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # Ractor-shareable, atomic counter.
  # This is a stateful, numeric object.
  #
  # The encapsulated value can be any numeric type, as long as it is either Ractor-shareable or can be coerced into a
  # Ractor-shareable type. This includes all of the built-in numeric types, as well as the likes of BigDecimal and
  # ActiveSupport::Duration.
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
  #   # Give the other rector time to run
  #   sleep 0.1
  #
  #   counter.value # => 6
  #
  # @example Counter as a numeric value
  #   counter = Farce::Counter.new(10.0)
  #   counter.to_i  # => 10
  #   counter + 5   # => 15.0
  #   2.5 * counter # => 25.0
  #
  #   require "active_support/all"
  #   counter.minutes.to_i # => 600
  class Counter < Farce::Abstract::Counter
    include Shareable

    # @return [Numeric] The current value of the counter.
    def value = @counter.value

    # Reset the counter to its initial value.
    # @return [self] Returns self for chaining.
    def reset
      @counter.value = @initial
      self
    end

    # Increment the counter by the given amount (default is 1).
    # @param [Numeric] by The amount to increment the counter by.
    # @return [self] Returns self for chaining.
    def increment(by = 1)
      @counter.add(Integer(by))
      self
    end

    private

    def prepare = @counter = Internal::Counter.new
  end
end
