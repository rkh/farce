# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Local
    # A shareable vector with independent mutable storage in each scope.
    #
    # @!method initialize(source = nil, compare_by_identity: false, scope: :ractor)
    #   @!macro scopes
    #   @param source [Array, nil] the initial values
    #   @param compare_by_identity [Boolean] whether values are compared by identity
    #   @param scope [Symbol] the scope of the vector
    #   @return [Vector]
    class Vector < Abstract::Vector
      include Shareable::Tracked
      include Scoped::Tracked

      protected def internal_vector = scoped_value
      private def new_scoped_value(...) = Internal::UnsharedVector.new(...)
    end
  end
end
