# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Local
    # A shareable weak value map with independent mutable storage in each scope.
    #
    # @!method initialize(initial_mapping = nil, scope: :ractor, **options)
    #   @!macro scopes
    #   @param initial_mapping [Hash, nil] the entries to store initially
    #   @param scope [Symbol] the scope of the weak value map
    #   @option options [Boolean] compare_by_identity (false) whether keys and values are compared by identity
    #   @option options [Boolean] compare_keys_by_identity (compare_by_identity) whether keys are compared by identity
    #   @option options [Boolean] compare_values_by_identity (compare_by_identity)
    #     whether values are compared by identity
    #   @return [WeakValueMap]
    class WeakValueMap < Abstract::WeakValueMap
      include Scoped

      private

      def internal_map          = scoped_value
      def new_scoped_value(...) = Internal::UnsharedWeakValueMap.new(...)
    end
  end
end
