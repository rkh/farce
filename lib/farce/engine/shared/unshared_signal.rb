# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal
    class UnsharedSignal < Signal
      def self.for(mode)
        raise ArgumentError, "fiber_wait must be :auto, :io, or :block" unless %i[auto io block].include?(mode)
        new
      end

      # Alternative engines keep their existing scheduler coordination.
      def fiber_wait = :auto
    end

    UnsharedIOSignal = UnsharedSignal
    UnsharedBlockSignal = UnsharedSignal
  end
end
