# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal # :nodoc: all
    # Coordinates one scheduler with its pool.
    class PoolWorker
      include Shareable

      def initialize(pool)
        @pool       = pool
        @inflight   = Counter.new if pool.max_inflight || pool.shrink_after
        @pressure   = pool.min_size < pool.max_size
        @registered = Atom.new(true)
        super()
      end

      def idle_timeout = @pool.shrink_after

      def wait_for_admission(scheduler, runnable_count)
        return false if @pool.drained?
        limit = @pool.max_inflight
        return true unless limit

        loop do
          return false if @pool.drained?
          return true if @pool.closing? || @pool.at_max_size? || @inflight.value < limit
          return true if runnable_count && scheduler.public_send(runnable_count).zero?

          generation = @pool.admission_generation
          next if @pool.closing? || @pool.at_max_size? || @inflight.value < limit
          @pool.wait_for_admission(generation)
        end
      end

      def task_started
        @inflight&.increment
        @pool.task_taken if @pressure
      end

      def task_finished
        return unless @inflight
        @inflight.decrement
        @pool.admission_changed if @pool.max_inflight && !@pool.at_max_size?
      end

      def retire?
        return false unless @inflight&.value&.zero?
        return false unless @pool.retire_worker
        @registered.compare_and_set(true, false)
      end

      def stopped(error, replace: true) # rubocop:disable Naming/PredicateMethod
        return false unless @registered.compare_and_set(true, false)
        @pool.worker_stopped(error, replace:)
        true
      end
    end
  end
end
