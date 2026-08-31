return if true

# @!visibility private
class Ractor
end

module Farce
  module Ractor
    # Either `Ractor::Port` or a shim for it. It is recommended to use {Farce::Port Farce::Port} instead,
    # which will always be a subclass of this class, but has added safety and functionality.
    class Port
      # Closes the port. Sending to a closed port is prohibited. Receiving is also prohibited if there are no
      # messages in its message queue. Only the Ractor which created the port is allowed to close it.
      # @return [void]
      def close = super
  
      # Checks it the port is closed.
      # @return [Boolean] `true` if the port is closed, `false` otherwise.
      # @see #close
      def closed? = super
  
      # @overload receive
      #   Receives a message from the port.
      #   @return [BasicObject] The received message.
      # @overload receive(timeout: nil)
      #   Receives a message from the port. Blocks until a message is available or the timeout is reached.
      #   @note
      #     Use {Farce::Port Farce::Port} instead to guarantee a timeout argument on all Ruby implementations.
      #   @ruby CRuby 4.1+, JRuby, TruffleRuby
      #   @param timeout [Numeric, nil] The timeout in seconds, or `nil` for no timeout.
      #   @return [BasicObject, nil] The received message, or `nil` if the timeout has been reached.
      #
      # @return [BasicObject]
      # @raise [Farce::Ractor::ClosedError] if the port is closed and there are no messages in the queue.
      def receive = super
  
      # Sends a message over the port.
      # @param message [BasicObject] The message to send.
      # @param move [Boolean] Whether to move the message to the Ractor if it isn't sharable.
      # @return [self]
      # @raise [Farce::Ractor::ClosedError] if the port is closed.
      def send(message, move: false) = super
      alias << send
    end
  end
end
