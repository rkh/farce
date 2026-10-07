# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # Shareable containers whose mutable contents belong to the current scope.
  # Scopes may be :ractor, :thread_group, :thread, :fiber_storage, or :fiber.
  # Initial contents are copied between Ractors. Within a Ractor, each scope has
  # its own container, but objects supplied as initial contents may be shared.
  module Local
    include Internal::Autoloads

    # @overload enfarce(object, freeze: nil, scope: :ractor)
    #   Converts vanilla Ruby objects into their {Farce::Local} equivalents.
    #
    #   @!macro scopes
    #
    #   @example
    #     Farce::Local.enfarce({ foo: ["bar"] })
    #     # =>  #<Farce::Local::Map {foo: #<Farce::Local::Vector ["bar"]>}>
    #
    #
    #   @yield [object] Optional block, called with any object that doesn't have a specific conversion defined.
    #   @yieldparam object [BasicObject] the object to convert
    #   @yieldreturn [BasicObject] the converted object
    #   @param object [BasicObject] The root object to convert
    #   @param freeze [Boolean, nil]
    #     Whether to freeze the converted objects.
    #     If set to `nil` (default), the freezing behavior will depend on the original object's frozen state.
    #   @param scope [Symbol] The scope for the local container, e.g., `:ractor`.
    #   @return [BasicObject] the converted object
    #   @see Farce.enfarce
    def self.enfarce(object, **, &) = Internal::Converter.new(self, **, &).convert(object)
  end
end
