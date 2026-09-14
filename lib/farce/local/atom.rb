# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Local
    # A shareable atomic reference with an independent mutable value in each scope.
    #
    # @!method initialize(value = nil, compare_by_identity: false, scope: :ractor)
    #   @!macro scopes
    #   @param value [BasicObject, nil] the initial value
    #   @param compare_by_identity [Boolean] whether comparisons use object identity instead of equality
    #   @param scope [Symbol] the scope of the atomic reference
    #   @return [Atom]
    class Atom < Abstract::Atom
      include Scoped

      private

      def internal_atom         = scoped_value
      def new_scoped_value(...) = Internal::UnsharedAtom.new(...)
    end
  end
end
