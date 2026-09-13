# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Unshared
    # A thread-safe map with weak values for use within one Ractor.
    #
    # @example Caching a mutable value without keeping it alive
    #   value = []
    #   map   = Farce::Unshared::WeakValueMap.new({ result: value })
    #   map[:result].equal?(value) # => true
    #
    #   # The entry can disappear once its value is collected.
    #   value = nil
    class WeakValueMap < Abstract::WeakValueMap
      include Unshareable

      def initialize(
        initial_mapping = nil,
        compare_by_identity: false,
        compare_keys_by_identity: compare_by_identity,
        compare_values_by_identity: compare_by_identity
      )
        @map = Internal::UnsharedWeakValueMap.new(
          initial_mapping,
          compare_by_identity:,
          compare_keys_by_identity:,
          compare_values_by_identity:,
        )
        super()
      end
    end
  end
end
