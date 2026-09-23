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
        selector = RactorSelector.for_call(self)
        selector ||= RactorSelector.current unless timeout.nil?
        selector ? selector.ractor_receive(self, timeout:) : super()
      end
    end
  end
end
