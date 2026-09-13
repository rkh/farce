# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Strict
    # A Ractor-shareable concurrent map that retains shareable keys and values weakly.
    #
    # @example Keeping a relationship while both objects remain alive
    #   key   = Object.new.freeze
    #   value = Object.new.freeze
    #   map   = Farce::Strict::WeakMap.new({ key => value })
    #   map[key].equal?(value) # => true
    #
    #   # The entry can disappear once its key or value is collected.
    #   value = nil
    class WeakMap < Abstract::WeakMap
      include Shareable

      def initialize(
        initial_mapping = nil,
        compare_by_identity: false,
        compare_keys_by_identity: compare_by_identity,
        compare_values_by_identity: compare_by_identity
      )
        @map = Internal::StrictWeakMap.new(
          initial_mapping,
          compare_by_identity:,
          compare_keys_by_identity:,
          compare_values_by_identity:,
        )
        super()
      end

      def shareable_keys? = true
      def shareable_values? = true
    end
  end
end
