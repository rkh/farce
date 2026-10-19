# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Concurrent
    # A replacement for `concurrent-ruby`'s `Concurrent::ThreadLocalVar`
    # @see https://ruby-concurrency.github.io/concurrent-ruby/master/Concurrent/ThreadLocalVar.html
    #
    # May or may not be Ractor-shareable depending on provided default values.
    #
    # @attribute [rw] value
    #   @return [Object] the current value of the thread-local variable
    #
    # @!method bind(value)
    #   @param value [Object] the value to bind to the thread-local variable
    #   @yield the block with the value bound to the thread-local variable
    #   @return [BasicObject] the result of the block
    class ThreadLocalVar < LocalVar
      # @overload initialize(default = nil)
      #   @param default [Object] the default value for the thread-local variable
      #
      # @overload initialize
      #   @yield the block to compute the default value for the thread-local variable
      def initialize(...) = super(:thread, ...)
    end
  end
end
