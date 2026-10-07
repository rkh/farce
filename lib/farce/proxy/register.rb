# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  class Proxy < BasicObject
    # Creates a new register for defining wrapper methods for proxy classes.
    # Helpful to isolate proxy definitions that shouldn't be activated globally.
    #
    # @example
    #   register = Farce::Proxy::Register.new
    #
    #   register.define(Hash) do
    #     # Don't send the fetch block to the proxied object
    #     # Allows blocks that aren't ractor-safe
    #     def fetch(*args)
    #       return super unless block_given?
    #       undefined = Object.new.freeze
    #       result    = super(args.first, undefined)
    #       undefined.equal?(result) ? yield(args.first) : result
    #     end
    #   end
    #
    #   default_proxy = Farce::Proxy.new({})
    #   custom_proxy  = Farce::Proxy.new({}, register:)
    #
    #   Ractor.new(default_proxy, custom_proxy) do |default_proxy, custom_proxy|
    #     default_proxy.fetch(:key) { Ractor.main? } # => true
    #     custom_proxy.fetch(:key) { Ractor.main? } # => false
    #   end
    class Register
      include Internal::MarshalSupport::Reject

      # Mixin extending the modules created by {Register#define}
      module Definition
        # Same as `Module#define_method`, but makes Proc definitions shareable across Ractors.
        #
        # @overload define_method(name)
        #   @param name [Symbol, String] the name of the method to define
        #   @yield block to define the method body
        #
        # @overload define_method(name, definition)
        #   @param name [Symbol, String] the name of the method to define
        #   @param definition [Proc, Method, UnboundMethod] the method body
        def define_method(name, definition = UNDEFINED, &block)
          if UNDEFINED.equal?(definition)
            return super(name) unless block
            definition = block
          end

          definition = Ractor.shareable_lambda(&definition) if definition.is_a?(Proc) && !Ractor.shareable?(definition)

          super(name, definition)
        end
      end

      include Farce::Shareable::Tracked

      # @api private
      attr_reader :inner_mirror, :outer_mirror

      def initialize
        @inner_mirror = ClassMirror.new(Wrapper::Inner)
        @outer_mirror = ClassMirror.new(Wrapper::Outer)
        super
      end

      # Created a new module that will be included in the proxy for the specified class and layer.
      # You can define methods using `def` within the block.
      # These methods may call `super` (which will ultimately delegate to the proxied object).
      #
      # The inner layer is invoked inside the Ractor the proxy resides in, while the outer layer is
      # invoked in the caller's Ractor.
      #
      # The wrapper objects do not have to be Ractor-shareable, so you may use instance variables for memoization.
      #
      # @param klass [Class] the class to define wrapper methods for
      # @param layer [Symbol] the layer of the proxy to define methods for (:inner or :outer)
      # @yield block to define wrapper methods for the proxied object
      # @yieldreceiver [Module] the module representing the wrapper layer, extended by {Definition}
      def define(klass, layer: :outer, &)
        check_frozen!
        mirror_for(layer).define(klass) do
          extend Definition

          module_eval(&)
        end
      end

      private

      def mirror_for(layer)
        case layer
        when :inner then @inner_mirror
        when :outer then @outer_mirror
        else raise ArgumentError, "Unknown layer: #{layer}"
        end
      end
    end
  end
end
