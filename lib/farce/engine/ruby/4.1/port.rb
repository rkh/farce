# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    BasePort = ::Ractor::Port
    class Port < BasePort
      include Freeze::Unfreezable

      def receive(timeout: nil)
        if selector = RactorSelector.for_call(self)
          selector.ractor_receive(self, timeout:)
        else
          timeout.nil? ? super() : super
        end
      end
    end
  end
end
