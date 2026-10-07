# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract Shared factory, caching, and delegation behavior for lazy values.
    class Lazy
      include Internal::MarshalSupport::Initialize
      include Internal::Copyable
      include Internal::Inspect
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
        @atom    = new_internal_atom
        super()
      end

      # The first time this method is called, the value will be computed based on the factory provided.
      # Subsequent calls will return the same value.
      #
      # Concurrent access computes the value once.
      # Shareable variants support calls from any Ractor.
      # @return [BasicObject] The value computed by the factory.
      def value
        atom  = internal_atom
        value = atom.value
        if value.nil?
          value = atom.store_if_absent do
            value = compute_value
            value.nil? ? UNDEFINED : value
          end
        end
        value unless UNDEFINED.equal?(value)
      end

      # @api private
      def marshal_dump
        current           = marshal_current_value
        resolved          = !current.nil?
        stored            = UNDEFINED.equal?(current) ? nil : current
        manager           = @manager if defined?(@manager)
        options           = {}
        options[:mode]    = manager.mode if manager
        options[:manager] = manager if manager
        options[:scope]   = scope if is_a?(Local::Lazy)

        # Other scopes still need their factory even when this scope is resolved.
        factory = @factory if !resolved || is_a?(Local::Lazy)

        [1, resolved, factory, Internal::MarshalSupport.value(stored), options, frozen?]
      end

      # @api private
      def marshal_load(data)
        resolved, factory, stored, options, frozen = Internal::MarshalSupport.payload(data, 5)
        @manager = options.delete(:manager) if options.key?(:manager)
        initialize(factory, **options)
        if resolved
          value = Internal::MarshalSupport.restore_value(stored)
          internal_atom.store(value.nil? ? UNDEFINED : value)
        end
        Internal::MarshalSupport.freeze(self, frozen)
      end

      # @api private
      def inspect_with(inspector)
        super do
          inspector.breakable
          display_value(inspector)
        end
      end

      private

      # @api private
      def marshal_current_value = internal_atom.value

      def internal_atom     = @atom
      def new_internal_atom = Internal::StrictAtom.new
      def compute_value     = @factory.is_a?(Class) ? @factory.new : @factory.call
      def prepare_proc(factory, **) = Ractor.shareable_proc(**, &factory)

      def prepare_factory(factory, **options, &block)
        Internal.self_option(options.dup)
        if block
          raise ArgumentError, "factory and block cannot be both given" unless factory.nil?
          factory = block
        end
        factory.is_a?(Proc) ? prepare_proc(factory, **options) : factory
      end

      def display_value(inspector, ...)
        case value = internal_atom.value
        when nil       then inspector.object(@factory, ...)
        when UNDEFINED then inspector.object(nil)
        else inspector.object(value, ...)
        end
      end

      # Delegates all method calls to {#value}.
      def method_missing(...) = value.public_send(...)
      def respond_to_missing?(...) = value.respond_to?(...)
    end
  end
end
