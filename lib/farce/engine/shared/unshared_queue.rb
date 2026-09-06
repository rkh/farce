# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal # :nodoc: all
    class UnsharedQueue < Queue
      def initialize(capacity: 1024, fiber_wait: :auto)
        raise ArgumentError, "fiber_wait must be :auto, :io, or :block" unless %i[auto io block].include?(fiber_wait)
        super(capacity:)
      end

      def fiber_wait = :auto

      private def check_value(_item); end
    end
  end
end
