# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal # :nodoc: all
    module UnsharedQueueWaiting
      # The resolved fiber waiting strategy. Other Ruby engines may return :auto.
      attr_reader :fiber_wait

      # @param fiber_wait [:auto, :io, :block] how scheduled fibers wait on CRuby
      def initialize(fiber_wait: :auto, **)
        @fiber_wait = fiber_wait
        super(**)
      end

      private

      def queue_signal
        signal = Internal::UnsharedSignal.for(@fiber_wait)
        @fiber_wait = signal.fiber_wait
        signal
      end

      def queue_storage_class = Internal::UnsharedPriorityQueue
    end
  end
end
