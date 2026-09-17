# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Keep reservation waits cancelable without shortening their overall deadline.
    module ReservationWaiting
      def self.wait(signal, generation, deadline)
        while true
          remaining = deadline - Clock.now if deadline
          return false if remaining && !remaining.positive?

          # LeaseWaiting supplies the full remaining timeout on default engines
          # and short cancellation slices on JRuby. Reuse that existing hook
          # without changing how other Signal users wait.
          interval = LeaseWaiting.wait_interval(remaining)
          return true if signal.wait(generation, timeout: interval) { false }
        end
      end
    end
  end
end
