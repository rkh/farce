# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # A task scheduler with a dynamically sized pool of workers.
    #
    # Pools accept work through {#schedule}. {#close} rejects new tasks and drains
    # queued work. Concrete pools use either Ractor or Thread workers.
    #
    # @abstract Use {Farce::Pool}, {Unshared::Pool}, or {Local::Pool}.
    class Pool < Executor
      include Internal::Inspect

      # @return [Float] Maximum queue wait before adding a worker.
      attr_reader :grow_after

      # @return [Integer, nil] Soft task limit for each worker.
      attr_reader :max_inflight

      # @return [Integer] Maximum worker count.
      attr_reader :max_size

      # @return [Integer] Minimum worker count.
      attr_reader :min_size

      # @return [Float, nil] Idle time before an extra worker retires.
      attr_reader :shrink_after

      # Create and start an elastic pool using the configured fiber scheduler.
      # An explicit constructor block overrides the configured default.
      #
      # `max_inflight` is a soft limit. A worker may exceed it when its scheduler
      # has no runnable fibers or when the pool has reached `max_size`.
      #
      # @param min_size [Integer] Workers started immediately and retained while open.
      # @param max_size [Integer] Maximum workers allowed.
      # @param max_inflight [Integer, nil] Soft task limit for each worker.
      # @param grow_after [Numeric] Queue wait before adding another worker.
      # @param shrink_after [Numeric, nil] Idle time before an extra worker retires.
      # @param capacity [Integer, nil] Pending-task capacity.
      # @param backend [Symbol] IO backend for the built-in scheduler.
      # @yieldreturn [Object] Fiber scheduler constructed in each worker.
      def initialize(min_size: 0, max_size: 4, max_inflight: 64,
                     grow_after: 0.005, shrink_after: 30, capacity: 1024,
                     backend: Internal::FROZEN_CONFIG.io_backend, &constructor)
        constructor ||= Internal::FROZEN_CONFIG.fiber_scheduler_constructor
        initialize_configuration(min_size:, max_size:, max_inflight:, grow_after:, shrink_after:, backend:)
        @constructor  = prepare_constructor(constructor)
        @queue        = new_queue(capacity: capacity && Integer(capacity))
        @state        = Internal::Atom.new(:running)
        @error        = Internal::Atom.new
        @worker_count = Internal::Atom.new(0)
        @pressure     = Internal::Atom.new
        @admission    = Internal::Signal.new
        super()
        publish_pool
        begin
          @min_size.times { start_worker }
        rescue Exception # rubocop:disable Lint/RescueException
          close
          raise
        end
      end

      # Enqueue a task for any worker in the pool.
      #
      # Ractor pools reject local transfer. Thread pools preserve the block and
      # arguments. With `auto_local: false`, they accept only local or smart modes.
      #
      # @!macro modes
      # @param args [Array<Object>] Positional arguments passed to the task block.
      # @param mode [Symbol] Argument transfer mode.
      # @param auto_local [Boolean] Whether to use local transfer in a thread pool.
      # @yield [*args] Task to execute.
      # @return [Pool] self.
      # @raise [PoolClosedError] If the pool is closing or closed.
      def schedule(*args, mode: :smart, auto_local: true, &block)
        raise PoolClosedError, "cannot schedule task on a closed pool" if closed?
        raise LocalJumpError, "Cannot schedule without a block" unless block

        task = prepare_task(args, block, mode, auto_local)
        @queue.push(task)
        arm_scaler
        self
      rescue ClosedQueueError
        raise unless closed?
        raise PoolClosedError, "cannot schedule task on a closed pool"
      end

      # Stop accepting tasks and drain queued work.
      #
      # @return [Pool] self.
      def close
        return self if closed?
        @state.compare_and_set(:running, :closing)
        @queue.seal
        admission_changed
        if size.zero?
          @queue.closed? ? finish_close : start_worker(drain: true)
        end
        self
      end

      # Return the first worker error, if any.
      def error
        value = @error.value
        value.is_a?(Envelope) ? value.value : value
      end

      # Return the current number of running and starting workers.
      def size = @worker_count.value

      # Return the current pool state.
      def state = @state.value

      # Return whether the pool rejects new tasks.
      def closed? = state != :running

      # Return whether the pool is draining queued work.
      def closing? = state == :closing

      # Return whether closing workers have drained all admitted submissions.
      # @api private
      def drained? = closing? && @queue.closed?

      # Return whether all configured workers have been started.
      def at_max_size? = size >= @max_size

      # Return the generation used by workers waiting for admission.
      # @api private
      def admission_generation = @admission.generation

      # Wait for worker capacity or a pool state change.
      # @api private
      def wait_for_admission(generation) = @admission.wait(generation)

      # Wake workers waiting at their soft admission limit.
      # @api private
      def admission_changed = @admission.broadcast

      # Record that a task left the shared queue.
      # @api private
      def task_taken
        return if @pressure.value.nil? || at_max_size?
        return unless queue_empty?
        @pressure.value = nil
        arm_scaler if @queue.size.positive?
      end

      # Reserve a worker retirement above the minimum size.
      # @api private
      def retire_worker
        retired = false
        @worker_count.update do |count|
          if state == :running && count > @min_size && queue_empty?
            retired = true
            count - 1
          else
            count
          end
        end
        retired
      end

      # Remove a stopped worker and preserve its failure.
      # @api private
      def worker_stopped(error, replace: true)
        @worker_count.update { |count| count - 1 }
        @error.compare_and_set(nil, Envelope.new(error)) if error
        if closing?
          if size.zero?
            error && !drained? ? start_worker(drain: true) : finish_close
          end
        elsif state == :running && replace
          begin
            start_worker while size < @min_size
          rescue Exception # rubocop:disable Lint/RescueException
            nil
          end
          arm_scaler if @queue.size.positive?
        end
        admission_changed
      end

      # Recheck delayed queue pressure and grow by one worker.
      # @api private
      def scale_if_needed(started)
        return unless state == :running && @pressure.value == started
        age = @queue.oldest_age
        return clear_pressure(started) unless age
        return reschedule_scaler(started, @grow_after - age) if age < @grow_after

        start_worker unless at_max_size?
        return clear_pressure(started) if queue_empty? || at_max_size?

        next_started = @queue.generation
        schedule_scaler(next_started) if @pressure.compare_and_set(started, next_started)
      rescue Exception => e # rubocop:disable Lint/RescueException
        @error.compare_and_set(nil, Envelope.new(e))
      end

      # @api private
      def inspect_with(inspector)
        super do
          inspector.attribute(:state,        state)
          inspector.attribute(:backend,      @backend)
          inspector.attribute(:size,         size)
          inspector.attribute(:min_size,     @min_size)
          inspector.attribute(:max_size,     @max_size)
          inspector.attribute(:max_inflight, @max_inflight) if @max_inflight
          yield if block_given?
        end
      end

      private

      def initialize_configuration(min_size:, max_size:, max_inflight:, grow_after:, shrink_after:, backend:)
        @min_size     = Integer(min_size)
        @max_size     = Integer(max_size)
        @max_inflight = max_inflight && Integer(max_inflight)
        @grow_after   = duration(grow_after, :grow_after)
        @shrink_after = duration(shrink_after, :shrink_after, nil_allowed: true)
        @backend      = backend
        validate_sizes
      end

      def prepare_constructor(constructor)
        return constructor if !constructor || Ractor.shareable?(constructor)
        Ractor.shareable_proc(&constructor)
      end

      def prepare_task(args, block, mode, _auto_local)
        raise ArgumentError, "local transfer is not supported by a pool" if mode == :local
        Internal::ScheduledTask.new(args, block, mode)
      end

      def new_queue(capacity:) = Internal::Queue.new(capacity:, track_age: true)
      def new_worker = Internal::PoolWorker.new(self)
      def new_scheduler(**, &) = Farce::Scheduler.new(**, &)
      def launch_scheduler(scheduler) = scheduler.launch_ractor

      def validate_sizes
        raise ArgumentError, "min_size must be non-negative" if @min_size.negative?
        raise ArgumentError, "max_size must be positive" unless @max_size.positive?
        raise ArgumentError, "min_size must not exceed max_size" if @min_size > @max_size
        raise ArgumentError, "max_inflight must be positive" if @max_inflight && !@max_inflight.positive?
      end

      def duration(value, name, nil_allowed: false)
        return if value.nil? && nil_allowed
        value = Float(value)
        raise ArgumentError, "#{name} must be finite and non-negative" if !value.finite? || value.negative?
        value
      end

      def start_worker(drain: false, only_if_empty: false)
        reserved = false
        @worker_count.update do |count|
          can_start = state == :running || (drain && closing? && !queue_empty?)
          if can_start && count < @max_size && (!only_if_empty || count.zero?)
            reserved = true
            count + 1
          else
            count
          end
        end
        return false unless reserved

        worker = new_worker
        scheduler = new_scheduler(
          backend:     @backend,
          queue:       @queue,
          pool_worker: worker,
          queue_owner: false,
          &@constructor
        )
        launch_scheduler(scheduler)
        admission_changed if at_max_size?
        true
      rescue Exception => e # rubocop:disable Lint/RescueException
        worker ? worker.stopped(e, replace: false) : @worker_count.update { |count| count - 1 }
        raise
      end

      def arm_scaler
        return if at_max_size? || queue_empty? || state != :running
        start_worker(only_if_empty: true) if size.zero?
        return if at_max_size?

        started = @queue.generation
        age     = @queue.oldest_age

        return unless age
        return unless @pressure.compare_and_set(nil, started)

        remaining = @grow_after - age
        remaining = 0 if remaining.negative?

        schedule_scaler(started, remaining)
      end

      def schedule_scaler(started, delay = @grow_after)
        Internal::PoolSupervisor.schedule(self, started, delay)
      end

      def reschedule_scaler(started, delay)
        next_started = @queue.generation
        schedule_scaler(next_started, delay) if @pressure.compare_and_set(started, next_started)
      end

      def clear_pressure(started)
        return unless @pressure.compare_and_set(started, nil)
        arm_scaler if @queue.size.positive?
      end

      def queue_empty? = @queue.size.zero? # rubocop:disable Style/ZeroLengthPredicate

      def finish_close = @state.compare_and_set(:closing, :closed)
    end
  end
end
