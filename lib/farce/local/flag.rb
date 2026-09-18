# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Local
    # A shareable atomic boolean with an independent value in each scope.
    # Only true and false are accepted. Read {#value} to test its state.
    class Flag
      include Abstract::Flag
      include Scoped

      # @!method initialize(value = false, scope: :ractor)
      #   @!macro scopes
      #   @param value [Boolean] the initial value
      #   @param scope [Symbol] the scope of the flag
      #   @raise [ArgumentError] if the value is not true or false

      # @return [Boolean] the current value
      def value = scoped_value.value

      alias get value

      # Set the flag to true.
      # @return [true]
      def set = scoped_value.set

      # Store a boolean value.
      # @param value [Boolean] the new value
      # @return [Boolean] the new value
      def store(value) = scoped_value.store(value)

      alias value= store

      # Replace the value and return its previous state.
      # @param value [Boolean] the new value
      # @return [Boolean] the previous value
      def swap(value) = scoped_value.swap(value)

      # Replace the value atomically if it matches the expected boolean.
      # @param expected [Boolean] the expected value
      # @param replacement [Boolean] the replacement value
      # @return [Boolean] whether the value changed
      def compare_and_set(expected, replacement) = scoped_value.compare_and_set(expected, replacement)

      # Atomically invert the value.
      # @return [Boolean] the new value
      def toggle = scoped_value.toggle

      private

      def new_scoped_value(...) = Internal::Flag.new(...)
    end
  end
end
