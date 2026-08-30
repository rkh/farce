# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    BasePort = ::Ractor::Port
    class Port < BasePort
      def receive(timeout: nil)
        return super() unless timeout
        Selector.ractor_receive(self, timeout:)
      end
    end
  end
end
