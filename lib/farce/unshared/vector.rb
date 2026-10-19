# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Unshared
    # A thread-safe vector for mutable values used within one Ractor.
    class Vector < Abstract::Vector
      include Unshareable
      include Internal::Freeze::Delegated

      # @param source [Array, Integer, nil] Initial values or a size filled with nil. Values are retained directly.
      # @param compare_by_identity [Boolean] Whether values are compared by identity.
      # @raise [ArgumentError] If the size is negative.
      def initialize(source = nil, compare_by_identity: false)
        @vector = Internal::UnsharedVector.new(normalize_vector_source(source), compare_by_identity:)
        super()
      end

      private def freeze_backend = @vector
    end
  end
end
