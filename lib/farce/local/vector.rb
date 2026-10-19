# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Local
    # A shareable vector with independent mutable storage in each scope.
    #
    # @!method initialize(source = nil, compare_by_identity: false, scope: :ractor)
    #   @!macro scopes
    #   @param source [Array, Integer, nil] Initial values or a size filled with nil.
    #   @param compare_by_identity [Boolean] whether values are compared by identity
    #   @param scope [Symbol] the scope of the vector
    #   @return [Vector]
    #   @raise [ArgumentError] If the size is negative.
    class Vector < Abstract::Vector
      include Shareable::Tracked
      include Scoped::Tracked

      protected

      def internal_vector = scoped_value

      def build_derived_vector(values)
        self.class.new(values, compare_by_identity: compare_by_identity?, scope:)
      end

      private def new_scoped_value(source = nil, **) = Internal::UnsharedVector.new(normalize_vector_source(source), **)
    end
  end
end
