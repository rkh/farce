# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Selects how long a Lease waits for one signal notification.
    module LeaseWaiting
      def self.wait_interval(remaining) = remaining
    end
  end
end
