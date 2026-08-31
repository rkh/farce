# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # Mixin that makes sure instances are shareable between Ractors.
  #
  # @example
  #   class MyClass
  #     include Farce::Shareable
  #   end
  #
  #   object = MyClass.new
  #   Ractor.shareable?(object) # => true
  module Shareable
    # Make sure to call `super` if you include this module.
    # Accepts any arguments and passes them on to the superclass initializer.
    def initialize(...)
      super
      ::Ractor.make_shareable(self) if Internal.native_ractors?
      freeze
    end

    # @return [Boolean] true
    # @see Unshareable#ractor_shareable?
    def ractor_shareable? = true
  end
end
