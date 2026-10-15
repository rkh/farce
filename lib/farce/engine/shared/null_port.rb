# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal
    class NullPort < Internal::Port
      def initialize       = nil # rubocop:disable Lint/MissingSuper
      def close            = raise Ractor::Error, "only allowed from the creator Ractor of this port"
      def closed?          = false
      def receive(...)     = raise Ractor::Error, "only allowed from the creator Ractor of this port"
      def send(...)        = self
      def inspect          = "Farce::NULL_PORT"
      def pretty_print(pp) = pp.text(inspect)
      alias << send
    end
  end
end
