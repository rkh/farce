# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Local
    # A shareable weak atom with independent mutable storage in each scope.
    #
    # @!method initialize(value = nil, compare_by_identity: false, scope: :ractor)
    #   @!macro scopes
    #   @param value [BasicObject, nil] the initial value
    #   @param compare_by_identity [Boolean] whether comparisons use object identity instead of equality
    #   @param scope [Symbol] the scope of the weak atomic reference
    #   @return [WeakAtom]
    class WeakAtom < Abstract::WeakAtom
      include Shareable::Tracked
      include Scoped::Tracked

      protected def internal_atom = scoped_value
      private def new_scoped_value(...) = Internal::UnsharedWeakAtom.new(...)
    end
  end
end
