# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal
    class NullPort < Internal::Port
      def self.new         = super(nil)
      def closed?          = false
      def inspect          = "Farce::NULL_PORT"
      def pretty_print(pp) = pp.text(inspect)

      def send(message, move: false)
        Ractor.new { receive }.send(message, move:) if move && !::Ractor.shareable?(message)
        self
      end

      alias << send
    end
  end
end
