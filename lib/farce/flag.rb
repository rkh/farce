# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A Ractor-shareable atomic boolean for coordinating threads and Ractors.
  # Only true and false are accepted. Read {#value} when testing the flag's state.
  # Use {#compare_and_set} to check and change the state in a single atomic operation.
  #
  # @example Allowing one caller to claim work
  #   claimed = Farce::Flag.new
  #   workers = 4.times.map do
  #     Thread.new { claimed.compare_and_set(false, true) }
  #   end
  #   workers.count { |worker| worker.value } # => 1
  #   claimed.value # => true
  #
  # @!method initialize(value = false)
  #   @param value [Boolean] the initial value
  #   @raise [ArgumentError] if the value is not true or false
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
  class Flag < Internal::Flag
    include Abstract::Value
    include Shareable
  end
end
