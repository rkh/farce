# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Strict
    # A Ractor-shareable rendezvous that exchanges shareable values directly.
    # Values retain their identity and envelopes are returned unopened.
    class Exchanger < Abstract::Exchanger
      include Shareable

      def initialize
        @exchanger = Internal::Exchanger.new
        super
      end

      # (see Abstract::Exchanger#exchange)
      # @raise [Ractor::IsolationError] if the offered value is not Ractor-shareable
      def exchange(offered, timeout: nil, &)
        raise Ractor::IsolationError, "value must be Ractor-shareable" unless Ractor.shareable?(offered)
        super
      end
    end
  end
end
