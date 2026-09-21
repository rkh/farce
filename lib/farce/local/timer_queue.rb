# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Local
    # A shareable timer queue with independent mutable storage in each scope.
    class TimerQueue < Abstract::TimerQueue
      include Shareable::Unfreezable
      include Scoped

      # @overload initialize(capacity: nil, track_age: false, scope: :ractor)
      #   @!macro scopes
      #   @param capacity [Integer, nil] the maximum number of values, or nil for an unbounded queue
      #   @param track_age [Boolean] whether to track enqueue age and queue generations
      #   @param scope [Symbol] the scope of the queue
      #   @param fiber_wait [:auto, :io, :block] how scheduled fibers wait on CRuby
      #   @return [TimerQueue]
      def initialize(capacity: nil, track_age: false, scope: :ractor, fiber_wait: :auto)
        super
      end

      # @return [Symbol] always returns `:local`
      def mode = :local

      # @api private
      def fiber_wait = internal_signal.fiber_wait

      private

      def eager_scoped_value? = false
      def internal_queue      = scoped_value.first
      def internal_signal     = scoped_value.last

      def new_scoped_value(capacity: nil, fiber_wait: :auto, track_age: false)
        signal = Internal::UnsharedSignal.for(fiber_wait)
        [Internal::UnsharedPriorityQueue.new(capacity:, signal:, track_age:), signal]
      end
    end
  end
end
