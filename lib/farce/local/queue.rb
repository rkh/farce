# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Local
    # A shareable queue with independent mutable storage in each scope.
    #
    # @!method initialize(capacity: 1024, track_age: false, scope: :ractor, **options)
    #   @!macro scopes
    #   @param capacity [Integer, nil] the maximum number of values, or nil for an unbounded queue
    #   @param track_age [Boolean] whether to track enqueue age and queue generations
    #   @param scope [Symbol] the scope of the queue
    #   @option options [:auto, :io, :block] fiber_wait (:auto) how scheduled fibers wait on CRuby
    #   @return [Queue]
    class Queue < Abstract::Queue
      include Scoped

      def mode = :local

      # @api private
      def fiber_wait = internal_queue.fiber_wait

      private

      def internal_queue        = scoped_value
      def new_scoped_value(...) = Internal::UnsharedQueue.new(...)
    end
  end
end
