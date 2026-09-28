# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  class Proxy < BasicObject
    # @api private
    class Wrapper < ::BasicObject # :nodoc: all
      include ::Farce.const_get(:Internal)::Delegation

      class Inner < self
        def initialize(object, ...)
          @__object__ = object
          super(...)
        end

        private

        # Dispatches method calls to @__object__
        def method_missing(...)      = @__object__.__send__(...)
        def respond_to_missing?(...) = @__object__.respond_to?(...)
      end

      class Outer < self
        private

        # Dispatches method calls to be processed by the Ractor the proxied object resides in.
        def method_missing(...)      = @__supervisor__.dispatch(...)
        def respond_to_missing?(...) = @__supervisor__.dispatch(:respond_to?, ...)
      end

      define_method(:respond_to?, ::Kernel.instance_method(:respond_to?))
      def initialize(supervisor) = @__supervisor__ = supervisor

      private

      def __wrap__(...)   = @__supervisor__.mode_manager.wrap(...)
      def __unwrap__(...) = @__supervisor__.mode_manager.unwrap(...)

      ::Farce::ModeManager::MODES.each do |mode|
        class_eval <<~RUBY, __FILE__, __LINE__ + 1
          private def __#{mode}__(object) = __wrap__(object, mode: :#{mode})
        RUBY
      end
    end

    private_constant :Wrapper
  end
end
