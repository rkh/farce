# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Local
    # A shareable handle with an independent thread pool in each scope.
    #
    # Each pool uses the scaling settings and fiber scheduler configured at
    # construction. Changing settings tunes the current scope's pool. New scopes
    # use the constructor settings. Tasks always keep their block and argument references. Only
    # local and smart modes are accepted when `auto_local` is false. A scheduler
    # constructor must be convertible to a shareable proc for use in each Ractor.
    # {#close} drains only the current scope's pool. {#close_all} drains every pool
    # across all scopes and Ractors, and prevents new pools from starting.
    #
    # @example Keep task state within each Ractor
    #   pool    = Farce::Local::Pool.new(max_size: 2)
    #   results = Farce::Unshared::Queue.new
    #   pool.schedule { results.push(:done) }
    #   results.pop # => :done
    #   pool.close_all
    class Pool < Abstract::Pool
      include Shareable::Unfreezable
      include Scoped
      include Internal::LocalExecutorMethods

      # (see Farce::Abstract::Pool#initialize)
      # @!macro scopes
      # @param scope [Symbol] The scope of the pool. Defaults to `:ractor`.
      def initialize(min_size: 0, max_size: 4, max_inflight: 64,
                     grow_after: 0.005, shrink_after: 30, capacity: 1024, scope: :ractor,
                     backend: Internal::FROZEN_CONFIG.io_backend, &constructor)
        initialize_configuration(min_size:, max_size:, max_inflight:, grow_after:, shrink_after:, backend:)
        @capacity           = capacity && Integer(capacity)
        @constructor        = prepare_constructor(constructor || Internal::FROZEN_CONFIG.fiber_scheduler_constructor)
        @pools              = Strict::Map.new
        @closed_all         = Internal::Flag.new(false)
        @initialization_key = Object.new.freeze
        super(scope:, min_size: @min_size, max_size: @max_size, max_inflight: @max_inflight,
              grow_after: @grow_after, shrink_after: @shrink_after, capacity:, backend:)
      end

      # Settings changes affect only the current scope. New scopes use constructor defaults.
      # @api private
      def settings = (pool = current_pool) ? pool.settings : @settings.value

      def capacity = (pool = current_pool) ? pool.capacity : @capacity

      def min_size=(value)
        scoped_value.min_size = value
      end

      def max_size=(value)
        scoped_value.max_size = value
      end

      def max_inflight=(value)
        scoped_value.max_inflight = value
      end

      def grow_after=(value)
        scoped_value.grow_after = value
      end

      def shrink_after=(value)
        scoped_value.shrink_after = value
      end

      def capacity=(value)
        scoped_value.capacity = value
      end

      # Stop accepting work in this scope and drain its queued tasks.
      # @return [self]
      def close
        pool = @closed_all.value ? Internal::Storage[self, scope:] : scoped_value
        pool&.close
        self
      end

      # Stop accepting work in every scope and Ractor and request draining.
      # Future scopes also reject submissions. Does not wait for running tasks.
      # @return [self]
      def close_all
        return self unless @closed_all.compare_and_set(false, true)
        @pools.each_pair do |pool, queue|
          queue.push([pool, :close].freeze, clock: 0)
        rescue ClosedQueueError
          # The owning Ractor may already have shut down its supervisor.
          nil
        end
        close
      end

      # @return [Integer] Running and starting workers in this scope.
      def size = current_pool&.size || 0

      # @return [Symbol] The current scope's pool state.
      def state = current_pool&.state || :closed

      # @return [Exception, nil] The first worker error in this scope.
      def error = current_pool&.error

      # @return [Boolean] Whether this scope rejects new tasks.
      def closed? = @closed_all.value || super

      Internal.delegate(self, :scoped_value, :drained?, :admission_generation, :wait_for_admission,
        :admission_changed, :task_taken, :retire_worker, :wake_retiring_workers,
        :worker_retired, :worker_stopped, :scale_if_needed)

      private

      def enqueue_task(non_block, ...)
        raise PoolClosedError, "cannot schedule task on a closed pool" if @closed_all.value
        pool = scoped_value
        submitted = non_block ? pool.try_schedule(...) : pool.schedule(...)
        submitted && self
      end

      def current_pool
        @closed_all.value ? Internal::Storage[self, scope:] : scoped_value
      end

      # Worker setup can yield. Initialize once when fibers share a scope.
      def scoped_value
        storage = Internal::Storage.scope(scope)
        pool    = storage[self]
        return pool if pool

        initializers = Internal::Storage.store_if_absent(@initialization_key) { Internal::Storage::ThreadSafe.new }
        initializers.store_if_absent(storage) { Internal::LeaseInitialization.new }.fetch { super }
      end

      def new_scoped_value(**)
        pool              = Unshared::Pool.new(**, &@constructor)
        queue, reference  = Internal::ThreadPoolSupervisor.current.close_handle(pool)
        @pools[reference] = queue
        pool.close if @closed_all.value
        pool
      end
    end
  end
end
