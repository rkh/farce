# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract Common interface and ownership tracking for Farce ports.
    # @note
    #   This is a module so both implementations can inherit directly from the runtime's port backend.
    #
    # @!method send(message)
    #   Sends a message through the port.
    #   @param message [BasicObject] the message to send
    #   @return [self]
    #   @raise [Farce::Ractor::ClosedError] if the port is closed
    #
    # @!method receive(timeout: nil)
    #   Waits for a message or the timeout. Only the owning Ractor can receive.
    #   @param timeout [Numeric, nil] the maximum seconds to wait, or nil to wait indefinitely
    #   @return [BasicObject, nil] the received message, or nil on timeout
    #   @raise [Farce::Ractor::ClosedError] if the port is closed
    #
    # @!method close
    #   Closes the port. Only the owning Ractor can close it.
    #   @return [self]
    #
    # @!method closed?
    #   @return [Boolean] whether the port is closed
    module Port
      include Internal::Noncopyable
      include Shareable::Native
      include Shareable::Unfreezable

      # @api private
      def initialize(...)
        # Native Ractor ports cannot hold Ruby instance variables.
        Internal::Storage.ractor[self] = true
        super
      end

      # Checks whether the current Ractor created this port.
      # @return [Boolean] whether the current Ractor owns the port
      def owned? = !!Internal::Storage.ractor[self]

      # Forwards all arguments to {#send}.
      # @return [self]
      def <<(...) = send(...)

      # Forwards all arguments to {#send}.
      # @return [self]
      def push(...) = send(...)

      # Forwards all arguments to {#receive}.
      # @return [BasicObject, nil] the received message, or nil on timeout
      def pop(...) = receive(...)

      # @api private
      def pretty_print(pp)
        string = inspect
        return pp.text(string) unless match = string.match(/\A#<([\w:]+)((?: \w+:#?\w+)+)>\z/)

        pp.group(1, "#<#{match[1]}", ">") do
          match[2].split.each do |pair|
            pp.breakable " "
            key, value = pair.split(":", 2)
            pp.text "#{key}:"
            pp.text value
          end
        end
      end
    end
  end
end
