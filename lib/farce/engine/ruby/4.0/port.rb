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
        selector = timeout.nil? ? RactorSelector.for_call(self) : RactorSelector.current
        selector ? selector.ractor_receive(self, timeout:) : super()
      end
    end
  end
end
