# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # Mixin that makes sure instances cannot be shared between Ractors.
  # Instances may be frozen without becoming Ractor-shareable.
  #
  # @example
  #   class MyClass
  #     include Farce::Unshareable
  #   end
  #
  #   object = MyClass.new
  #   object.freeze # Preserves the Ractor restrictions.
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

    # Make sure to call `super` if you include this module.
    # Accepts any arguments and passes them on to the superclass initializer.
    def initialize(...)
      pin_unshareable
      super
    end

    # @return [Boolean] false
    # @see Shareable#ractor_shareable?
    def ractor_shareable? = false

    private

    def pin_unshareable
      return unless Internal.native_ractors?
      case self
      when Movable
        if is_a?(Copyable)
          Internal::Unshareable.prevent_shareable(self)
        else
          Internal::Unshareable.prevent_copyable(self)
        end
      when Copyable then Internal::Unshareable.prevent_movable(self)
      else Internal::Unshareable.pin_to_current_ractor(self)
      end
    end
  end
end
