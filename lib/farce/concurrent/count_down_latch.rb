# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Concurrent
    # A replacement for `concurrent-ruby`'s `CountDownLatch` implementation.
    # @see https://ruby-concurrency.github.io/concurrent-ruby/master/Concurrent/CountDownLatch.html
    class CountDownLatch
      include Shareable::Delegated
      include Internal::Noncopyable

      # @param count [Integer] the initial count for the latch.
      # @raise [ArgumentError] if the count is not a non-negative integer.
      def initialize(count = 1)
        raise ArgumentError, "count must be a non-negative integer" unless count.is_a?(Integer) && count >= 0
        @counter = Counter.new(count)
        super()
      end

      # @!attribute [r] count
      #   @return [Integer] the current count of the latch.
      def count = @counter.value

      # Decrements the count of the latch by 1 if it is above 0.
      # @return [void]
      def count_down = @counter.decrement_if_above(0)

      # Waits until the count reaches 0 or the optional timeout is reached.
      # @param timeout [Numeric, nil] the maximum time to wait in seconds, or nil to wait indefinitely.
      # @return [Boolean] true if the count reached 0, false if the timeout was reached.
      def wait(timeout = nil) = !!@counter.wait_while_above(0, timeout:) # rubocop:disable Naming/PredicateMethod

      private def freeze_backend = @counter
    end
  end
end
