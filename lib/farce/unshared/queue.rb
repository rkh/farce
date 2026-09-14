# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Unshared
    # A FIFO queue that stores and returns values directly.
    class Queue < Abstract::Queue
      include Unshareable

      def initialize(capacity: 1024, fiber_wait: :auto, track_age: false)
        @queue = Internal::UnsharedQueue.new(capacity:, fiber_wait:, track_age:)
        super()
      end

      def mode = :local

      # The resolved fiber waiting strategy. Other Ruby engines may return :auto.
      # @api private
      def fiber_wait = @queue.fiber_wait
    end
  end
end
