# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Local
    # A shareable atomic counter with an independent value in each scope.
    # Each scope starts at the initial integer. Reset affects only the current scope.
    class Counter < Numeric
      include Abstract::Counter
      include Shareable::Tracked
      include Scoped::Tracked

      # The initial value used for new scopes and by {#reset}.
      # @return [Integer]
      attr_reader :initial

      # @!macro scopes
      # @param value [Numeric, String, #to_int] the initial value, converted to an Integer
      # @param scope [Symbol] the scope of the counter
      def initialize(value = 0, scope: :ractor)
        raise FrozenError.new("can't initialize a frozen counter", receiver: self) if frozen?
        @initial = Integer(value)
        super(@initial, scope:)
      end

      # Return the current integer value.
      # @return [Integer]
      def value = internal_counter.value

      alias get value

      # Store an integer value.
      # @param value [Integer] the replacement value
      # @return [Integer] the stored value
      def store(value) = internal_counter.store(value)

      alias value= store

      # Replace the value and return the previous integer.
      # @param value [Integer] the replacement value
      # @return [Integer]
      def swap(value) = internal_counter.swap(value)

      # Replace the value atomically if it matches the expected integer.
      # @param expected [Integer] the expected value
      # @param replacement [Integer] the replacement value
      # @return [Boolean] whether the value changed
      def compare_and_set(expected, replacement) = internal_counter.compare_and_set(expected, replacement)

      # Increment the counter atomically.
      # @param by [Numeric, String, #to_int] the amount, converted to an Integer
      # @return [self]
      def increment(by = 1)
        internal_counter.increment(by)
        self
      end

      # Decrement the counter atomically.
      # @param by [Numeric, String, #to_int] the amount, converted to an Integer
      # @return [self]
      def decrement(by = 1)
        internal_counter.decrement(by)
        self
      end

      alias subtract decrement
      alias remove   decrement

      private

      def marshal_initialize(arguments, options, configuration)
        @initial = Integer(arguments.first)
        super
      end

      def initialize_copy(other)
        # Numeric#initialize_copy cannot copy mutable Numeric subclasses on JRuby.
        @farce_freeze_state = Internal::Flag.new(false)
        Internal::Storage.scope(scope)[self] = Internal::Counter.new(other.value)
      end

      def change_signal         = internal_counter.change_signal
      def internal_counter      = scoped_value
      def new_scoped_value(...) = Internal::Counter.new(...)
    end
  end
end
