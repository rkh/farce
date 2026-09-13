# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Unshared
    # A thread-safe vector for mutable values used within one Ractor.
    class Vector < Abstract::Vector
      include Unshareable

      # @param source [Array, nil] Initial values. Values are retained directly.
      # @param compare_by_identity [Boolean] Whether values are compared by identity.
      def initialize(source = nil, compare_by_identity: false)
        @vector = Internal::UnsharedVector.new(source, compare_by_identity:)
        super()
      end
    end
  end
end
