# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Strict
    # A Ractor-shareable concurrent map that stores shareable keys and values directly.
    #
    # @example Atomically counting occurrences
    #   counts = Farce::Strict::Map.new
    #   counts.upsert(:ruby, 1) { |count| count + 1 } # => 1
    #   counts.upsert(:ruby, 1) { |count| count + 1 } # => 2
    class Map < Abstract::ConcurrentMap
      include Shareable

      def initialize(
        initial_mapping = nil,
        compare_by_identity: false,
        compare_keys_by_identity: compare_by_identity,
        compare_values_by_identity: compare_by_identity
      )
        @map = Internal::StrictMap.new(
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
