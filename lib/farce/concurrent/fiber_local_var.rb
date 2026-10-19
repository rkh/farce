# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Concurrent
    # A replacement for `concurrent-ruby`'s `Concurrent::FiberLocalVar`
    # @see https://ruby-concurrency.github.io/concurrent-ruby/master/Concurrent/FiberLocalVar.html
    #
    # May or may not be Ractor-shareable depending on provided default values.
    #
    # @attribute [rw] value
    #   @return [Object] the current value of the fiber-local variable
    #
    # @!method bind(value)
    #   @param value [Object] the value to bind to the fiber-local variable
    #   @yield the block with the value bound to the fiber-local variable
    #   @return [BasicObject] the result of the block
    class FiberLocalVar < LocalVar
      # @overload initialize(default = nil)
      #   @param default [Object] the default value for the fiber-local variable
      #
      # @overload initialize
      #   @yield the block to compute the default value for the fiber-local variable
      def initialize(...) = super(:fiber, ...)
    end

    # Alias for `FiberLocalVar` to maintain compatibility with `LockLocalVar`
    LockLocalVar = FiberLocalVar
  end
end
