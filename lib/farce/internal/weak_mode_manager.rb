# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Prepare values without introducing a wrapper with an independent lifetime.
    class WeakModeManager < ModeManager
      MODES = %i[raise make_shareable dedup].freeze

      def initialize(mode: :raise)
        validate_mode!(mode)
        super
      end

      def validate_mode!(mode)
        selected = nil.equal?(mode) ? self.mode : mode
        return selected if MODES.include?(selected)
        raise ArgumentError, "unsupported weak value mode: #{selected.inspect}"
      end

      def wrap(value, mode: nil) = super(value, mode: validate_mode!(mode))
    end
  end
end
