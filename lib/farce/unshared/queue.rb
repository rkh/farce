# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Unshared
    # A FIFO queue that stores and returns values directly.
    class Queue < Abstract::Queue
      include Unshareable

      # @param fiber_wait [:auto, :io, :block] how scheduled fibers wait on CRuby
      def initialize(capacity: 1024, fiber_wait: :auto)
        @queue = Internal::UnsharedQueue.new(capacity:, fiber_wait:)
        super()
      end

      def mode = :local

      # The resolved fiber waiting strategy. Other Ruby engines may return :auto.
      def fiber_wait = @queue.fiber_wait
    end
  end
end
