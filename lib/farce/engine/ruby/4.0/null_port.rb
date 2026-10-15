# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal
    class NullPort < ::Ractor::Port
      class << self
        alias new! new
      end

      def self.new
        retriever = ::Ractor::Port.new

        ::Ractor.new(retriever) do |retriever|
          null_port = NullPort.new!
          retriever.send(null_port)

          Thread.current.priority = -15
          Darwin.set_qos_class(Darwin::BACKGROUND, Darwin::MIN_RELATIVE_PRIORITY) if defined? Darwin.set_qos_class
          null_port.receive while true
        end

        retriever.receive
      ensure
        retriever&.close
      end

      def send(_, move: false) = move ? super : self
      def inspect              = "Farce::NULL_PORT"
      def pretty_print(pp)     = pp.text(inspect)

      alias << send
    end
  end
end
