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
  class Flag < Internal::Flag
    include Abstract::Flag
    include Shareable
  end
end
