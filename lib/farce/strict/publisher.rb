# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Strict
    # Strict variant of {Farce::Publisher}.
    class Publisher < Farce::Abstract::Publisher
      include Shareable::Unfreezable

      # @overload initialize(*subscribers)
      #   (see Farce::Abstract#initialize)
      def initialize(*subscribers)
        @map = Strict::Map.new
        super()
        subscribers.each { subscribe(it) }
      end

      # (see Farce::Abstract::Publisher#publish)
      def publish(message = nil)
        return super if Ractor.shareable?(message)
        raise Ractor::IsolationError, "value must be Ractor-shareable"
      end
      alias send      publish
      alias <<        publish
      alias broadcast publish

      private attr_reader :map
    end
  end
end
