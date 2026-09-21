# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Strict
    # A priority queue that stores and returns values directly.
    class PriorityQueue < Abstract::PriorityQueue
      include Internal::StrictQueueValues unless Internal.native_ractors?
      include Shareable::Unfreezable

      def initialize(capacity: nil, default_priority: 0, order: :ascending, track_age: false)
        unless Ractor.shareable?(default_priority)
          raise Ractor::IsolationError, "default priority is not Ractor-shareable"
        end
        super
      end
    end
  end
end
