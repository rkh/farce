# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract Shared factory, caching, and delegation behavior for lazy values.
    class Lazy
      include Value

      # @overload initialize(factory)
      #   @param [Class, Proc, #call] factory The factory to use for creating the value. Must be ractor-shareable.
      #
      # @overload initialize(self: nil)
      #   @yield The block to use for creating the value. Must be ractor-shareable.
      #   @yieldreceiver [BasicObject] The `self` parameter provided, or `nil` if not provided.
      #   @yieldreturn [BasicObject] The value to be returned by the lazy instance.
      #   @param [BasicObject] self The `self` parameter to be provided to the block. Must be ractor-shareable.
      def initialize(factory = nil, **, &)
        @factory = prepare_factory(factory, **, &)
        @atom    = Internal::Atom.new
        super()
      end

      # The first time this method is called, the value will be computed based on the factory provided.
      # Subsequent calls will return the same value.
      #
      # This is thread-safe and may be called from any Ractor, even concurrently.
      # @return [BasicObject] The value computed by the factory.
      def value
        value = internal_atom.store_if_absent do
          value = @factory.is_a?(Class) ? @factory.new : @factory.call
          value.nil? ? UNDEFINED : value
        end
        value unless UNDEFINED.equal?(value)
      end

      # @return [String] Returns a string representation of the lazy instance.
      def inspect = "#<#{self.class.name} #{display_value.inspect}>"

      # @api private
      # @return [void]
      def pretty_print(pp) = pp.group(1, "#<#{self.class.name} ", ">") { pp.pp(display_value) }

      private

      def internal_atom = @atom

      def prepare_factory(factory, **, &block)
        if block
          raise ArgumentError, "factory and block cannot be both given" unless factory.nil?
          factory = block
        end
        factory.is_a?(Proc) ? Ractor.shareable_proc(**, &factory) : factory
      end

      def display_value
        value = internal_atom.value
        return @factory if value.nil?

        value unless UNDEFINED.equal?(value)
      end

      # Delegates all method calls to {#value}.
      def method_missing(...) = value.public_send(...)
      def respond_to_missing?(...) = value.respond_to?(...)
    end
  end
end
