# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Strict
    # A Ractor-shareable port that accepts shareable messages directly.
    # Messages retain their identity and envelopes are returned unopened.
    # Only the creating Ractor can receive messages or close the port.
    #
    # @example Receive an already prepared message
    #   port    = Farce::Strict::Port.new
    #   message = [:ready, 42].freeze
    #   port << message
    #   port.receive.equal?(message) # => true
    #   port.close
    #
    # @!method initialize
    #   Creates a port without transfer modes.
    class Port < Internal::Port
      include Abstract::Port

      # @!visibility private
      # (see #initialize)
      # CRuby 3.4's backend also accepts an existing port or Ractor.
      # Keep construction argument-free on every runtime.
      def self.new = super # rubocop:disable Lint/UselessMethodDefinition

      # (see Abstract::Port#send)
      # @raise [Farce::Ractor::IsolationError] if the message is not Ractor-shareable
      def send(message)
        raise Ractor::IsolationError, "value must be Ractor-shareable" unless Ractor.shareable?(message)
        super
      end

      # @return [String] a string representation of the port
      def inspect = super.sub(/\A#<.+? (?=(?:to|id):#?\d+)/, "#<Farce::Strict::Port ")
    end
  end
end
