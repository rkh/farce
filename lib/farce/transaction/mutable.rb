# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  class Transaction
    # A {Farce::Mutable} that stages method calls within a transaction.
    #
    # Reads use the attempt's current snapshot. Mutations replace only its staged
    # value and are published with the other participants when the attempt commits.
    # Snapshots must be frozen. Use a dedicated transaction participant for a
    # shareable object whose state can change while it remains unfrozen.
    class Mutable < Farce::Mutable
      include Wrapper

      # @api private
      def initialize(transaction, object, backend)
        super
        @atom = Atom.new(transaction, object, backend)
        return if @atom.value.frozen?
        ::Kernel.raise(::TypeError, "mutable transactions require a frozen snapshot")
      end

      # @api private
      def marshal_dump = ::Kernel.raise(::TypeError, "transaction wrappers cannot be marshaled")

      # @api private
      def respond_to?(name, include_private = false) # rubocop:disable Style/OptionalBooleanParameter
        access { name != :freeze && super }
      end

      # @api private
      def frozen? = access { @object.frozen? }

      private

      # Wrapper's error guards must raise locally rather than delegate to the value.
      def raise(...) = ::Kernel.raise(...)

      def method_missing(name, ...) # rubocop:disable Style/MissingRespondToMissing
        access do
          ::Kernel.raise(::NoMethodError, "transaction wrappers cannot be frozen") if name == :freeze
          begin
            @atom.value.__send__(name, ...)
          rescue ::FrozenError
            result = nil
            @atom.update do |current|
              copy = current.dup
              result = copy.__send__(name, ...)
              result = self if result.equal?(copy)
              copy.freeze
            end
            result
          end
        end
      end

      Wrapper.inherit(self, :is_a?, :pretty_print_cycle)
    end
  end
end
