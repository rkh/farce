# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    module FlagWaiting
      # Wait until the current value differs from the expected value.
      # @param expected [Boolean] the value to wait to change from
      # @param timeout [Numeric, nil] the total seconds available
      # @yield called when the timeout expires
      # @return [Boolean, BasicObject, nil] the changed value or timeout fallback
      # @raise [ArgumentError] if expected is not true or false
      def wait_until_changed(expected, timeout: nil)
        unless expected.equal?(true) || expected.equal?(false)
          raise ArgumentError, "expected value must be true or false"
        end
        signal = change_signal
        Internal.with_timeout(timeout) do |_, deadline|
          observed = signal.generation
          current = value
          return current unless expected == current
          break unless signal.wait(observed, timeout: Internal.remaining_timeout(deadline))
        end
        yield if block_given?
      end
    end
  end
end
