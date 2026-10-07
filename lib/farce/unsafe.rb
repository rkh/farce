# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # Module holding classes with instances which are not thread-safe and cannot be shared between Ractors.
  module Unsafe
    include Unshared
    include Internal::Autoloads

    # @overload enfarce(object, freeze: nil)
    #   Converts vanilla Ruby objects into their {Farce::Unsafe} equivalents.
    #
    #   @example
    #     Farce::Unsafe.enfarce({ foo: ["bar"] })
    #     # =>  #<Farce::Unsafe::Map {foo: #<Farce::Unsafe::Vector ["bar"]>}>
    #
    #   @yield [object] Optional block, called with any object that doesn't have a specific conversion defined.
    #   @yieldparam object [BasicObject] the object to convert
    #   @yieldreturn [BasicObject] the converted object
    #   @param object [BasicObject] The root object to convert
    #   @param freeze [Boolean, nil]
    #     Whether to freeze the converted objects.
    #     If set to `nil` (default), the freezing behavior will depend on the original object's frozen state.
    #   @return [BasicObject] the converted object
    #   @see Farce.enfarce
    def self.enfarce(object, **, &) = Internal::Converter.new(self, **, &).convert(object)
  end
end
