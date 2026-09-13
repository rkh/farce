# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract Common superclass for weak atomic references.
    #
    # A weak atom does not keep its current value alive. Its value becomes `nil`
    # after garbage collection when no strong references remain. Collection
    # timing is controlled by the garbage collector. In-flight operations may
    # temporarily retain values they observe. Updates are serialized even when
    # collection changes the observed value.
    class WeakAtom < Atom
      # @param value [BasicObject, nil] the initial value
      # @param compare_by_identity [Boolean] whether comparisons use object identity instead of equality
      def initialize(value = nil, compare_by_identity: false)
        @atom = internal_atom_class.new(value, compare_by_identity:)
        super()
      end

      private

      # @abstract
      # simplecov:disable
      def internal_atom_class
        raise NoMethodError, "Farce::Abstract::WeakAtom should not be instantiated directly. Use a subclass instead."
      end
      # simplecov:enable
    end
  end
end
