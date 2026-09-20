# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract Common boolean interface and serialization for atomic flags.
    # @note This is a module rather than a class so {Farce::Flag} can inherit
    #   directly from the native flag and avoid delegation overhead.
    #
    # @!method value
    #   @return [Boolean] the current value
    #
    # @!method set
    #   Set the flag to true.
    #   @return [true]
    #
    # @!method store(value)
    #   Set the flag to the given value.
    #   @param value [Boolean] the new value
    #   @return [Boolean] the new value
    #   @raise [ArgumentError] if the value is not true or false
    #
    # @!method value=(value)
    #   Alias for {#store}
    #
    # @!method swap(value)
    #   Replace the value and return its previous state.
    #   @param value [Boolean] the new value
    #   @return [Boolean] the previous value
    #   @raise [ArgumentError] if the value is not true or false
    #
    # @!method compare_and_set(expected_value, replacement_value)
    #   Replace the value only if it matches the expected value.
    #   @param expected_value [Boolean] the expected current value
    #   @param replacement_value [Boolean] the new value
    #   @return [Boolean] whether the replacement succeeded
    #   @raise [ArgumentError] if either argument is not true or false
    #
    # @!method toggle
    #   Atomically invert the value.
    #   @return [Boolean] the new value
    module Flag
      include Internal::Copyable
      include Value
      include ValueSerialization
    end
  end
end
