# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # Shareable containers that store shareable values directly.
  module Strict
    include Internal::Autoloads

    # @overload enfarce(object, freeze: nil)
    #   Converts vanilla Ruby objects into their {Farce::Strict} equivalents.
    #
    #   @example
    #     Farce::Strict.enfarce({ foo: ["bar"] }) { Ractor.make_shareable(it) }
    #     # =>  #<Farce::Strict::Map {foo: #<Farce::Strict::Vector ["bar"]>}>
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
