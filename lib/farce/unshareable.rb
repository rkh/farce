# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # Mixin that makes sure instances cannot be shared between Ractors.
  # @note Mixin in this module will remove the `freeze` method from the class.
  #
  # @example
  #   class MyClass
  #     include Farce::Unshareable
  #   end
  #
  #   object = MyClass.new
  #   object.freeze # this would normally make it shareable
  #
  #   Ractor.shareable?(object) # => false
  module Unshareable
    # Mixin for classes that cannot be shared across Ractors, but may be moved between them.
    module Movable
      include Unshareable
    end

    # Mixin for classes that cannot be shared across Ractors, but may be copied between them.
    module Copyable
      include Unshareable
    end

    # @api private
    module UndefFreeze # :nodoc: all
      # @api private
      def append_features(mod)
        if mod.is_a?(Class)
          mod.class_eval { undef freeze if method_defined?(:freeze) }
        else
          mod.extend(UndefFreeze)
        end
        super
      end
    end

    private_constant :UndefFreeze
    extend UndefFreeze

    # Make sure to call `super` if you include this module.
    # Accepts any arguments and passes them on to the superclass initializer.
    def initialize(...)
      if Internal.native_ractors?
        case self
        when Movable  then Internal::Unshareable.prevent_copyable(self) unless is_a?(Copyable)
        when Copyable then Internal::Unshareable.prevent_movable(self)
        else Internal::Unshareable.pin_to_current_ractor(self)
        end
      end
      super
    end

    # @return [Boolean] false
    # @see Shareable#ractor_shareable?
    def ractor_shareable? = false
  end
end
