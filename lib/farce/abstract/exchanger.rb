# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # A rendezvous where callers pair up and receive each other's offered value.
    # Each call participates in one exchange. The exchanger can be reused by any number of callers.
    class Exchanger
      include Internal::Noncopyable

      # Wait for a partner and return the partner's value.
      # Offering nil allows a caller to receive a value without sending a payload.
      # A timeout of zero only exchanges with a partner that is already waiting.
      # A successful exchange of nil does not invoke the fallback.
      #
      # @param offered [BasicObject, nil] the value to give to the partner
      # @param timeout [Numeric, nil] the maximum seconds to wait, or nil to wait indefinitely
      # @yield called without arguments when the timeout expires
      # @return [BasicObject, nil] the partner's value, or the fallback result or nil on timeout
      # @raise [ArgumentError] if the timeout is negative or not finite
      def exchange(offered, timeout: nil, &) = @exchanger.exchange(offered, timeout:, &)
    end
  end
end
