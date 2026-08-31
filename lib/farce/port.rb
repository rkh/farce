# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!parse
  #   class Port < Farce::Ractor::Port
  #   end
  #
  # `Ractor::Port` subclass with additional features.
  class Port < Internal::Port
    include Shareable

    # {Farce::Ractor::Port#send Sends} a message over the port.
    #
    # @overload send(message)
    #   @param message [BasicObject] The message to send.
    #
    # @overload send(message, move:)
    #   @param message [BasicObject] The message to send.
    #   @param move [Boolean] Whether to move the message to the receiving Ractor.
    #
    # @overload send(message, mode:)
    #   @param message [BasicObject] The message to send.
    #   @param mode [Symbol] The mode to use for sending the message.
    #
    # @return [self]
    # @raise [Farce::Ractor::ClosedError] if the port is closed.
    def send(message, move: UNDEFINED, mode: UNDEFINED)
      case mode_for(message, move, mode)
      when :shareable then super(message)
      else raise "TODO: not implemented"
      end
    end

    # {Farce::Ractor::Port#receive Receives} a value from the port, with an optional timeout.
    #
    # Always supports the `timeout:` keyword argument, even on Ruby implementations that don't support it.
    #
    # Does not block an active Fiber scheduler, even if the scheduler implementation isn't Ractor-aware.
    #
    # @param timeout [nil, Numeric] The number of seconds to wait for a value
    # @return [BasicObject, nil] The value received from the port, or `nil` if the timeout has been reached
    def receive(timeout: nil) = super

    private

    def mode_for(message, _move, _mode)
      :shareable if Ractor.shareable?(message)
    end
  end
end
