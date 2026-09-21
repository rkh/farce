# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Strict
    # A Ractor-shareable vector that stores and returns shareable values directly.
    class Vector < Abstract::Vector
      include Shareable::Delegated

      # @param source [Array, nil] Initial values. The source array is not retained.
      # @param compare_by_identity [Boolean] Whether values are compared by identity.
      def initialize(source = nil, compare_by_identity: false)
        @vector = Internal::Vector.new(source, compare_by_identity:)
        super()
      end

      # (see Farce::Abstract::Vector#shareable_values?)
      def shareable_values? = true

      private def freeze_backend = @vector
    end
  end
end
