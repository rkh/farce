# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    module LeaseWaiting
      MIN = 0.05

      # JRuby delivers Thread#raise after its Java Phaser wait returns.
      # Bound each wait so cancellation remains responsive.
      def self.wait_interval(remaining)
        return MIN if !remaining || remaining > MIN
        remaining
      end
    end
  end
end
