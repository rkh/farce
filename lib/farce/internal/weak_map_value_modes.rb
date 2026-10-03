# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    module WeakMapValueModes
      include MapValueModes

      # Values follow the selected mode. Keys must already be shareable.
      # @param mode [Symbol] :raise, :make_shareable, or :dedup
      def initialize(initial_mapping = nil, mode: :raise, **options)
        super
      end

      def store(key, value, mode: nil, **)
        @manager.validate_mode!(mode)
        super
      end

      def swap(key, replacement, mode: nil, **)
        @manager.validate_mode!(mode)
        super
      end

      def store_if_absent(key, mode: nil, **)
        raise LocalJumpError, "no block given" unless block_given?
        @manager.validate_mode!(mode)
        super
      end

      def update(key, mode: nil, **)
        raise LocalJumpError, "no block given" unless block_given?
        @manager.validate_mode!(mode)
        super
      end

      def upsert(key, initial, mode: nil, **)
        raise LocalJumpError, "no block given" unless block_given?
        @manager.validate_mode!(mode)
        super
      end

      def compare_and_set(key, expected, replacement, mode: nil, **)
        @manager.validate_mode!(mode)
        super
      end

      private

      def new_mode_manager(mode:) = WeakModeManager.new(mode:)

      # Expected values are comparison operands, not values to publish.
      def wrap_comparison(value) = nil.equal?(value) ? NIL_VALUE : value
    end
  end
end
