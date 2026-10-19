# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Local
    # A shareable handle with an independent task scheduler in each scope.
    #
    # {.new} leaves each scheduler unstarted. Launch it with {#launch_thread}, or
    # install it with `Fiber.set_scheduler`. {.create} starts a worker thread in
    # each scope when that scope is first used. The default scope is `:ractor`.
    #
    # Tasks retain their blocks and argument references. {#execute} runs directly
    # in the calling fiber. A fiber scheduler
    # constructor must be convertible to a shareable proc for use in each Ractor.
    # {#close} closes the current scope. {#close_all} closes all scopes and prevents
    # new schedulers from starting. {.current} returns an {Unshared::Scheduler}.
    #
    # @example Start one worker in each Ractor
    #   scheduler = Farce::Local::Scheduler.create
    #   results = Farce::Unshared::Queue.new
    #   scheduler.schedule { results.push(:done) }
    #   results.pop # => :done
    #   scheduler.close_all
    class Scheduler < Abstract::Scheduler
      include Shareable::Unfreezable
      include Scoped
      include Internal::LocalExecutorMethods

      # Returns the current thread's unshared scheduler, or nil when none is installed.
      # @param (see Abstract::Scheduler.current)
      # @return [Unshared::Scheduler, nil]
      def self.current(**) = Unshared::Scheduler.current(**)

      # Starts a worker in this scope and retains the launch settings for other scopes.
      # Additional options and the block are forwarded to {#initialize}.
      # @param executor [Class, nil] Thread or a custom executor that stays in each Ractor.
      # @param name [String, nil] Optional worker name.
      # @param priority [Integer, nil] Optional worker thread priority.
      # @yieldreturn [Object] Fiber scheduler to install in each worker.
      # @return [Scheduler]
      def self.create(executor = Thread, name: nil, priority: nil, **, &)
        raise ArgumentError, "Local schedulers cannot launch Ractor workers" if executor && executor <= Ractor
        worker = [executor || Thread, name && -String(name), priority && Integer(priority)].freeze
        new(**, worker:, &)
      end

      # Creates a handle whose scoped schedulers remain unstarted.
      # The constructor block builds the fiber scheduler when a scope is launched or installed.
      # @!macro scopes
      # @overload initialize(capacity: 1024, backend: Farce.config.io_backend, scope: :ractor, &constructor)
      #   @param capacity [Integer, nil] Pending-task capacity, or nil for an unbounded queue in each scope.
      #   @param backend [Symbol] IO backend for the built-in scheduler.
      #   @param scope [Symbol] The scheduler scope. Defaults to :ractor.
      #   @yieldreturn [Object] Fiber scheduler to install in each scope.
      def initialize(capacity: 1024, backend: Internal::FROZEN_CONFIG.io_backend, scope: :ractor,
                     worker: nil, &constructor)
        @constructor        = prepare_constructor(constructor || Internal::FROZEN_CONFIG.fiber_scheduler_constructor)
        @capacity           = capacity && Integer(capacity)
        @backend            = backend
        @worker             = worker
        @schedulers         = Strict::Map.new
        @closed_all         = Internal::Flag.new(false)
        @initialization_key = Object.new.freeze
        @registration_key   = Object.new.freeze
        super(scope:, capacity: capacity && Integer(capacity), backend:)
      end

      # Pending-task capacity in this scope. New scopes retain the constructor value.
      def capacity = (scheduler = current_scheduler) ? scheduler.capacity : @capacity

      # Resize the queue in this scope without starting a worker.
      def capacity=(value)
        raise SchedulerClosedError, "cannot configure a closed scheduler" if @closed_all.value
        scoped_value.capacity = value
      end

      # Enqueue a task in the current scope, preserving its block and arguments.
      # `mode` is ignored when `auto_local` is true. Otherwise, only local and smart modes are accepted.
      # @overload schedule(*args, mode: :smart, auto_local: true)
      #   @param (see Farce::Abstract::Executor#schedule)
      #   @return [self]
      def schedule(...) = enqueue_task(false, ...)

      # (see Abstract::Scheduler#try_schedule)
      def try_schedule(...) = enqueue_task(true, ...)

      # Starts a worker for the current scope. Other scopes retain their creation behavior.
      # @param executor [Class, nil] Thread or a custom executor that stays in this Ractor.
      # @param name [String, nil] Optional worker name.
      # @param priority [Integer, nil] Optional worker thread priority.
      # @return [Thread, Object] The worker.
      # @raise [ArgumentError] If a Ractor executor is supplied.
      def launch(executor = Thread, name: nil, priority: nil)
        raise ArgumentError, "Local schedulers cannot launch Ractor workers" if executor && executor <= Ractor
        raise "Scheduler may not be reused" if @closed_all.value
        active_scoped_value.launch(executor, name:, priority:)
      end

      # Closes the current scope and rejects new submissions there.
      # @return [self]
      def close
        current_scheduler&.close
        self
      end

      # Requests shutdown in every scope and Ractor and rejects future scopes.
      # Does not wait for queued or running tasks to finish.
      # @return [self]
      def close_all
        return self unless @closed_all.compare_and_set(false, true)
        @schedulers.each_pair do |scheduler, queue|
          queue.push([scheduler, :close].freeze, clock: 0)
        rescue ClosedQueueError
          # The owning Ractor may already have shut down its supervisor.
          nil
        end
        close
      end

      # @return [Symbol] The current scope's scheduler state.
      def state = current_scheduler&.state || :closed

      # @return [Exception, nil] The current scope's scheduler error.
      def error = current_scheduler&.error

      # @return [Boolean] Whether the current scope rejects new tasks.
      def closed? = @closed_all.value || scoped_value.closed?

      # @return [Boolean] Whether the current scope is dispatching tasks.
      def alive? = current_scheduler&.alive? || false

      # @return [Ractor] The current scope's owning Ractor.
      def owner = Ractor.current

      # @param value [Ractor] The current Ractor.
      # @raise [ArgumentError] If another owner is supplied.
      def owner=(value)
        raise ArgumentError, "owner must be the current Ractor" unless value == Ractor.current
      end

      # @return [Boolean] Whether a fiber scheduler constructor was supplied.
      def wraps_external? = !@constructor.nil?

      # @return [Object, nil] The fiber scheduler in the current scope, when supplied by a constructor.
      def external_scheduler = current_scheduler&.external_scheduler

      # @api private
      def inspect_with(inspector)
        inspector.object_group(self) do
          inspector.attribute(:scope, scope)
          inspector.attribute(:state, state)
          inspector.attribute(:backend, @backend)
          yield if block_given?
        end
      end

      private

      def enqueue_task(non_block, *, mode: :smart, auto_local: true, &block)
        raise SchedulerClosedError, "cannot schedule task on a closed scheduler" if @closed_all.value
        scheduler = scoped_value
        raise SchedulerClosedError, "cannot schedule task on a closed scheduler" if scheduler.closed?
        raise LocalJumpError, "Cannot schedule without a block" unless block

        validate_local_mode(mode, auto_local)
        register_scheduler(scheduler)

        submitted =
          if non_block
            scheduler.try_schedule(*, mode:, auto_local:, &block)
          else
            scheduler.schedule(*, mode:, auto_local:, &block)
          end

        submitted && self
      end

      def current_scheduler
        return scoped_value unless @closed_all.value
        scheduler = Internal::Storage[self, scope:]
        scheduler&.close
        scheduler
      end

      # Worker setup can yield. Initialize once when fibers share a scope.
      def scoped_value
        storage = Internal::Storage.scope(scope)
        scheduler = storage[self]
        return scheduler if scheduler

        initializers = Internal::Storage.store_if_absent(@initialization_key) { Internal::Storage::ThreadSafe.new }
        initializers.store_if_absent(storage) { Internal::LeaseInitialization.new }.fetch { super }
      end

      def active_scoped_value
        scheduler = scoped_value
        register_scheduler(scheduler)
        scheduler
      end

      def register_scheduler(scheduler)
        registrations = Internal::Storage.store_if_absent(@registration_key) { Internal::Storage::ThreadSafe.new }
        registrations.store_if_absent(scheduler) do
          queue, reference = Internal::ThreadPoolSupervisor.current.close_handle(scheduler)
          @schedulers[reference] = queue
          true
        end
        scheduler.close if @closed_all.value
      end

      def new_scoped_value(**)
        scheduler = Unshared::Scheduler.new(**, &@constructor)
        if @worker && !@closed_all.value
          register_scheduler(scheduler)
          executor, name, priority = @worker
          scheduler.launch(executor, name:, priority:) unless @closed_all.value
        end
        scheduler.close if @closed_all.value
        scheduler
      end

      def set_scheduler!(...)
        raise "Scheduler may not be reused" if @closed_all.value
        active_scoped_value.set_scheduler!(...)
      end
    end
  end
end
