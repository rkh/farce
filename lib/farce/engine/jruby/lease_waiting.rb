# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    module LeaseWaiting
      # JRuby delivers Thread#raise after its Java Phaser wait returns.
      # Bound each wait so cancellation remains responsive.
      def self.wait_interval(remaining)
        return 0.05 unless remaining

        [remaining, 0.05].min
      end
    end
  end
end
