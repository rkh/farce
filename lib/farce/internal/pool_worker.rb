# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal # :nodoc: all
    # Coordinates one scheduler with its pool.
    class PoolWorker
      include Shareable::Unfreezable

      def initialize(pool)
        @pool = pool
        @inflight = Counter.new
        @registered = Atom.new(true)
        super()
      end

      def settings = @pool.settings
      def idle_timeout = settings.shrink_after

      def wait_for_admission(scheduler, runnable_count, settings = self.settings)
        loop do
          return false if @pool.drained?
          return settings if @pool.closing?
          count = @pool.size
          limit = settings.max_inflight
          return false if count > settings.max_size && retire?(excess: true)
          # Busy workers keep queued dependencies runnable until they become idle.
          return settings if !limit || count >= settings.max_size || @inflight.value < limit
          return settings if runnable_count && scheduler.public_send(runnable_count).zero?

          # Read the generation before rechecking state to avoid a lost configuration wakeup.
          generation = @pool.admission_generation
          settings = self.settings
          count = @pool.size
          limit = settings.max_inflight
          next if @pool.closing? || !limit || count >= settings.max_size || @inflight.value < limit
          @pool.wait_for_admission(generation)
          settings = self.settings
        end
      end

      def task_started(settings = self.settings)
        @inflight.increment
        @pool.task_taken(settings)
      end

      def task_finished
        @inflight.decrement
        settings = self.settings
        count = @pool.size
        if count > settings.max_size
          @inflight.value.zero? ? @pool.wake_retiring_workers : @pool.admission_changed
        elsif settings.max_inflight && count < settings.max_size
          @pool.admission_changed
        end
      end

      def retire?(excess: false, expected: nil)
        return false unless @inflight.value.zero?
        return false unless @pool.retire_worker(excess:, expected:)
        retired = @registered.compare_and_set(true, false)
        @pool.worker_retired if retired
        retired
      end

      def stopped(error, replace: true) # rubocop:disable Naming/PredicateMethod
        return false unless @registered.compare_and_set(true, false)
        @pool.worker_stopped(error, replace:)
        true
      end
    end
  end
end
