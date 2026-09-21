# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Local
    # A shareable priority queue with independent mutable storage in each scope.
    class PriorityQueue < Abstract::PriorityQueue
      include Shareable::Unfreezable
      include Scoped

      # @overload initialize(capacity: nil, default_priority: 0, order: :ascending, scope: :ractor, track_age: false)
      #   @!macro scopes
      #   @param capacity [Integer, nil] the maximum number of values, or nil for an unbounded queue
      #   @param default_priority [BasicObject] the shareable priority used when none is passed to push or try_push
      #   @param order [:ascending, :descending] the priority order
      #   @param scope [Symbol] the scope of the priority queue
      #   @param track_age [Boolean] whether to track enqueue age and queue generations
      #   @param fiber_wait [:auto, :io, :block] how scheduled fibers wait on CRuby
      #   @return [PriorityQueue]
      def initialize(
        capacity: nil, default_priority: 0, order: :ascending, scope: :ractor,
        track_age: false, fiber_wait: :auto
      )
        unless Ractor.shareable?(default_priority)
          raise Ractor::IsolationError, "default_priority must be Ractor-shareable"
        end

        @order            = normalize_order(order)
        @default_priority = default_priority
        @reverse_order    = @order == :descending
        super(capacity:, scope:, track_age:, fiber_wait:)
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
