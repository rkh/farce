# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Unshared
    # A thread-safe atomic reference that retains values directly within one Ractor.
    # Mutable values keep their identity. Updates are serialized between threads.
    #
    # @example Updating an array atomically
    #   atom = Farce::Unshared::Atom.new([])
    #   atom.update { |items| items + [:job] }
    class Atom < Abstract::Atom
      include Unshareable

      # @param value [BasicObject, nil] the initial value
      # @param compare_by_identity [Boolean] whether comparisons use object identity
      def initialize(value = nil, compare_by_identity: false)
        @atom = Internal::UnsharedAtom.new(value, compare_by_identity:)
        super()
      end
    end
  end
end
