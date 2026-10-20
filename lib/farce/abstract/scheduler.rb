# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # A task scheduler for one worker or an installed fiber scheduler.
    #
    # Use {.create} to start a worker, or install an instance on the current
    # thread with `Fiber.set_scheduler`. {#close} rejects new submissions and
    # drains queued tasks. A scheduler can only be launched or installed once.
    #
    # @abstract Use {Farce::Scheduler}, {Unshared::Scheduler}, or {Local::Scheduler}.
    class Scheduler < Executor
      include Internal::Inspect

      CLOSED_STATES = ::Set[:closed, :closing, :error].freeze
      private_constant :CLOSED_STATES

      # Returns a Farce scheduler for the current thread's installed fiber scheduler.
      # Returns `nil` when no fiber scheduler is installed.
      #
      # Creates and installs a wrapper when necessary, starting its dispatcher on
      # that scheduler.
      #
      # Additional keyword arguments are forwarded to {#initialize} when wrapping.
      #
      # @example Create a scheduler for Async, and send it to a different Ractor
      #   require "async"
      #   require "farce"
      #
      #   # No fiber scheduler set here
      #   Farce::Scheduler.current # => nil
      #
      #   Async do
      #     # A scheduler that will hand tasks to Async::Scheduler
      #     scheduler = Farce::Scheduler.current # => #<Farce::Scheduler>
      #
      #     # This looks like doing the same as nested Async { ... } calls or
      #     # Fiber.schedule { ... }, …
      #     scheduler.schedule { puts "Scheduled from the main Ractor" }
      #
      #     # … but it can be called from other threads and ractors
      #     Ractor.new(scheduler) do |scheduler|
      #       scheduler.schedule { puts "Scheduled from a background Ractor" }
      #     end
      #   end
      #
      # @example Full circle
      #   scheduler = Farce::Scheduler.new
      #   Farce::Scheduler.current # => nil
      #   Fiber.set_scheduler(scheduler)
      #   Farce::Scheduler.current == scheduler # => true
      # @return [Scheduler, nil]
      def self.current(**)
        return unless Fiber.respond_to?(:scheduler)
        return unless scheduler = Fiber.scheduler
        register = Internal::Storage.store_if_absent(self) { Internal::Storage.new }
        register.store_if_absent(scheduler) do
          wrapper = new(**, external: true)
          wrapper.__send__(:set_scheduler!, scheduler:)
          wrapper
        end
      end

      # Creates a new scheduler and starts it in a background ractor, thread, or custom executor.
      #
      # @overload create(executor = nil, name: nil, priority: nil, capacity: 1024, backend: Farce.config.io_backend)
      #   Runs tasks on the configured fiber scheduler. The backend option selects
      #   the IO driver when using Farce's built-in scheduler.
      #
      #   @example
      #     scheduler = Farce::Scheduler.create
      #     scheduler.schedule { puts "Running on the built-in scheduler" }
      #
      #   @param executor [Class, nil] Ractor or Thread, nil selects the runtime default.
      #   @param name [String, nil] Optional worker name.
      #   @param priority [Integer, nil] Optional worker thread priority.
      #   @param capacity [Integer, nil] Pending-task capacity, nil creates an unbounded queue.
      #   @param backend [Symbol] IO backend for the built-in scheduler, defaults to Farce configuration.
      #   @return [Scheduler]
      #
      # @overload create(executor = nil, name: nil, priority: nil, capacity: 1024, &block)
      #   Runs tasks on a fiber scheduler supplied by your block. Use this to send
      #   work through Farce to another library's event loop, such as Async.
      #
      #   Construct and return the scheduler inside the block: Farce calls it once
      #   in the worker, where that event loop will run, and installs the result.
      #   The block configures the scheduler. Submit actual tasks with {#schedule}.
      #   Configure any IO backend on the returned scheduler itself. Farce's backend
      #   option is ignored when a block is supplied.
      #
      #   {Farce::Scheduler} requires a Ractor-shareable block. Require the library before calling
      #   create and avoid capturing a scheduler created on another thread or Ractor.
      #
      #   @example Run tasks on Async in a worker thread
      #     require "async"
      #     require "farce"
      #
      #     # Using Thread as an executor as at the moment Async cannot run on a non-main Ractor
      #     scheduler = Farce::Scheduler.create(Thread) { Async::Scheduler.new }
      #     scheduler.schedule { puts "Running on Async" }
      #
      #   @example Run tasks on CarbonFiber in a worker ractor
      #     require "carbon_fiber"
      #     require "farce"
      #
      #     scheduler = Farce::Scheduler.create(Ractor) { CarbonFiber::Scheduler.new }
      #     scheduler.schedule { puts "Running on CarbonFiber" }
      #
      #   @param executor [Class, nil]
      #     Ractor or Thread. `nil` selects the runtime default.
      #     Choose an executor supported by the supplied scheduler and its dependencies.
      #   @param name [String, nil] Optional worker name.
      #   @param priority [Integer, nil] Optional worker thread priority.
      #   @param capacity [Integer, nil] Pending-task capacity, nil creates an unbounded queue.
      #   @yieldreturn [Object] The fiber scheduler to install in the worker.
      #   @return [Scheduler]
      # @see #launch
      def self.create(executor = nil, name: nil, priority: nil, **, &)
        new(**, &).tap { it.launch(executor, name:, priority:) }
      end

      # Creates a scheduler without starting a worker. Use this instead of {.create}
      # when you want to launch it later with {#launch}, or install it on the current
      # thread with `Fiber.set_scheduler(scheduler)`.
      #
      # @overload initialize(capacity: 1024, backend: Farce.config.io_backend)
      #   Uses the configured fiber scheduler when launched or installed.
      #
      #   @param capacity [Integer, nil] Pending-task capacity, nil creates an unbounded queue.
      #   @param backend [Symbol] IO backend for the built-in scheduler, defaults to Farce configuration.
      #
      # @overload initialize(capacity: 1024, &block)
      #   Uses another library's fiber scheduler while retaining Farce's ability to
      #   accept tasks from other threads and Ractors.
      #
      #   Supply a block that constructs and returns that scheduler. The block runs
      #   once when this handle is launched or installed, in the thread that will
      #   run the tasks, rather than during new. {Farce::Scheduler} requires a
      #   Ractor-shareable block. {Unshared::Scheduler} may capture local state.
      #   Farce installs its result. Submit tasks separately with {#schedule}.
      #   Configure the supplied scheduler in the block. Farce's backend option is
      #   ignored for this overload.
      #
      #   @example Choose Async, then launch the worker later
      #     require "async"
      #     require "farce"
      #
      #     scheduler = Farce::Scheduler.new { Async::Scheduler.new }
      #     worker = scheduler.launch_thread
      #     scheduler.schedule { puts "Running on Async" }
      #
      #   @param capacity [Integer, nil] Pending-task capacity, nil creates an unbounded queue.
      #   @yieldreturn [Object] The fiber scheduler to install when launched or installed.
      def initialize(capacity: 1024, backend: Internal::FROZEN_CONFIG.io_backend, queue: nil, external: false,
                     pool_worker: nil, queue_owner: true, &constructor)
        constructor ||= Internal::FROZEN_CONFIG.fiber_scheduler_constructor
        @capacity    = capacity ? Integer(capacity) : nil
        @backend     = backend
        @constructor = prepare_constructor(constructor)
        @external    = external || !constructor.nil?
        @owner       = Internal::Atom.new(nil)
        @state       = Internal::Atom.new(:initialized)
        @error       = Internal::Atom.new
        @queue       = queue || new_queue(capacity: @capacity)
        @pool_worker = pool_worker
        @queue_owner = queue_owner
        super()
      end

      # Pending-task capacity. Nil means the queue is unbounded.
      def capacity = @queue.capacity

      # Resize the pending queue without discarding tasks.
      # JRuby and TruffleRuby cannot switch between bounded and unbounded queues.
      def capacity=(value)
        @queue.capacity = value.nil? ? nil : Integer(value)
      end

      # @return [Exception, nil] The error encountered by the scheduler, if any.
      def error
        value = @error.value
        value.is_a?(Envelope) ? value.value : value
      end

      # @overload launch_ractor(name: nil, priority: nil)
      #   Launches a Ractor worker. Accepts the keyword arguments of {#launch}.
      #   @param name [String, nil] Optional worker name.
      #   @param priority [Integer, nil] Optional worker thread priority.
      #   @return [Ractor] The worker.
      def launch_ractor(...) = launch(Ractor, ...)

      # @overload launch_thread(name: nil, priority: nil)
      #   Launches a Thread worker. Accepts the keyword arguments of {#launch}.
      #   @param name [String, nil] Optional worker name.
      #   @param priority [Integer, nil] Optional worker thread priority.
      #   @return [Thread] The worker.
      def launch_thread(...) = launch(Thread, ...)

      # Starts dispatching tasks in a new worker and waits for setup to leave its
      # launching/setup states before returning. Returns the created worker instance.
      #
      # @example Using the return value to assign a ThreadGroup
      #   scheduler = Farce::Scheduler.new
      #   worker    = scheduler.launch_thread
      #   group     = ThreadGroup.new
      #
      #   group.add(worker)
      #   group.enclose
      #
      # @example Using a custom worker
      #   class MyWorker
      #     def initialize(...)
      #       # flip a coin whether we're using Ractor or Thread
      #       @worker = [Ractor, Thread].sample.new(...)
      #     end
      #
      #     def join = @worker.join
      #   end
      #
      #   scheduler = Farce::Scheduler.new
      #   scheduler.launch(MyWorker)
      #
      # @param executor [Class, nil]
      #   Ractor or Thread. Defaults to Ractor when native Ractors are available, otherwise Thread.
      # @param name [String, nil] Optional worker name.
      # @param priority [Integer, nil] Optional worker thread priority.
      # @return [Ractor, Thread, Object] The worker.
      # @raise [RuntimeError] If this handle has already been launched, installed, or closed.
      def launch(executor = nil, name: nil, priority: nil)
        raise "Scheduler may not be reused" unless @state.compare_and_set(:initialized, :launching)

        executor ||= Internal.native_ractors? ? Ractor : Thread
        priority &&= Integer(priority)
        name     &&= -String(name)
        callback   = launch_callback

        return executor.new(self, priority, name, &callback) unless executor <= Ractor
        # Requiring an autoloaded implementation from a new Ractor can deadlock
        # while its launcher waits for setup to finish.
        Internal.const_get(:FiberScheduler, false)
        Internal.const_get(:Storage, false)
        Internal.const_get(:ThreadPool, false)
        executor.new(self, priority, name, name:, &callback)
      rescue Exception => e # rubocop:disable Lint/RescueException
        @state.value = :error
        @error.value = Envelope.new(e)
        raise
      ensure
        # if we return the thread too early, someone could kill it while another threads blocks on a schedule call
        if System.windows? && executor <= Ractor
          sleep 0.001 while @state.value == :launching
          sleep 0.001 while @state.value == :setup
        else
          @state.wait_until_changed(:launching)
          @state.wait_until_changed(:setup)
        end
      end

      # @return [Ractor, nil] The owning Ractor, or nil before ownership is assigned.
      def owner = @owner.value

      # Assigns ownership during setup. An existing owner cannot be changed.
      # This is used by schedule to determine if a task is scheduled locally or remotely.
      #
      # If {#schedule} is called without setting `auto_local` to false, it will block until the owner can be determined.
      # Setting the owner explicitly avoids blocking on ownership determination.
      #
      # @example
      #   scheduler = Farce::Scheduler.new
      #
      #   # Scheduler hasn't been launched, so it could block.
      #   scheduler.owner = Ractor.current
      #
      #   # Now this doesn't block
      #   scheduler.schedule { some_task }
      #
      #   # Can use #launch_thread, but #launch_ractor would fail now that the owner is set.
      #   scheduler.launch_thread
      #
      # @param value [Ractor, nil]
      # @raise [ArgumentError] If value is not a Ractor/nil or changes an assigned owner.
      def owner=(value)
        raise ArgumentError, "owner must be a Ractor" unless value.nil? || value.is_a?(Ractor)
        return if @owner.compare_and_set(nil, value)
        return if owner == value
        raise ArgumentError, "owner has already been set"
      end

      # @return [Boolean] Whether a fiber scheduler constructor was supplied.
      def wraps_external? = @external

      # Retrieves the constructed external scheduler from its owning Ractor.
      # @return [Object, nil]
      #   The external scheduler, or nil before setup or when using the built-in scheduler.
      # @raise [Ractor::IsolationError]
      #   If called outside the owning Ractor for an external scheduler.
      def external_scheduler
        return unless wraps_external?
        return Internal::Storage[self] if owner.nil? || owner == Ractor.current
        raise Ractor::IsolationError, "external_scheduler is owned by a different Ractor"
      end

      # Enqueues a task, waiting for queue space if necessary. Returns after
      # submission. It does not wait for task completion or return the task's value.
      #
      # With `auto_local` enabled, waits for ownership to be assigned and uses `:local`
      # mode whenever the caller and owner are in the same Ractor, including different
      # threads in that Ractor.
      #
      # Local tasks retain their block and arguments.
      #
      # Otherwise, the block must be convertible to a Ractor-shareable proc.
      # Pass task data as arguments so the selected transfer mode can be applied to it.
      #
      # A `timeout` limits the combined wait for ownership and queue space.
      # Expiry returns `nil` without enqueuing the task. Accepted tasks have no execution timeout.
      #
      # @overload schedule(*args, mode: :smart, auto_local: true, timeout: nil)
      #   @!macro modes
      #
      #   @param args [Array<Object>] Positional arguments passed to the task block.
      #   @param mode [Symbol]
      #     Argument transfer mode from {Farce::MODES}, including `:copy`, `:marshal`, and `:local`.
      #     See {ModeManager#wrap}.
      #   @param auto_local [Boolean] Whether to override mode with `:local` in the owning Ractor.
      #   @param timeout [Numeric, nil] Maximum scheduling wait in seconds. Nil waits indefinitely, zero polls.
      #   @yield [*args] The task to execute.
      #   @return [self, nil] self when submitted, or nil when the scheduling timeout expires.
      #   @raise [SchedulerClosedError] If the handle is closing, closed, or in an error state.
      #   @see Ractor.shareable_proc
      def schedule(...) = enqueue_task(false, ...)

      # Enqueues a task without waiting for queue space.
      # Arguments and transfer modes follow {#schedule}. With `auto_local` enabled,
      # it still waits for ownership to be assigned.
      #
      # @overload try_schedule(*args, mode: :smart, auto_local: true)
      #   @param args (see Farce::Abstract::Executor#schedule)
      #   @param mode (see Farce::Abstract::Executor#schedule)
      #   @param auto_local (see Farce::Abstract::Executor#schedule)
      #   @return [self, nil] self when submitted, or nil when the queue is full.
      def try_schedule(*, mode: :smart, auto_local: true, &)
        enqueue_task(true, *, mode:, auto_local:, &)
      end

      # (see Farce::Abstract::Executor#local?)
      def local?(wait: true)
        owner = wait ? @owner.wait_until_non_nil : @owner.value
        owner == Ractor.current
      end

      # Requests shutdown and rejects further submissions. Repeated calls are harmless.
      # The dispatcher drains queued tasks before closing the queue. This method
      # does not wait for dispatch or running tasks to finish.
      #
      # This wakes a dispatcher blocked on an empty queue. It does not directly
      # close the underlying fiber scheduler.
      # @return [Scheduler] self.
      def close
        until closed?
          state = @state.value
          @state.compare_and_set(state, :closing) unless CLOSED_STATES.include?(state)
        end
        # if the scheduler never acquired an owner, #schedule might be blocked
        @owner.compare_and_set(nil, Ractor.current)
        @queue_owner ? @queue.seal : wake_dispatcher
        self
      end

      # @return [Symbol]
      #   The current state of the scheduler. One of:
      #   * `:initialized`: The scheduler has been created but not yet launched.
      #   * `:launching`: The scheduler is in the process of being {#launch launched} on a background worker.
      #   * `:setup`: The scheduler is in the process of being setting up a fiber scheduler.
      #   * `:running`: The scheduler is actively dispatching tasks.
      #   * `:closing`: The scheduler has been requested to shut down and is draining its queue.
      #   * `:closed`: The scheduler has finished shutting down.
      #   * `:error`: The scheduler encountered an error during dispatch.
      def state = @state.value

      # @return [Boolean]
      #   Whether new submissions are rejected, including while
      #   closing or after a dispatch error.
      #   Does not imply all tasks have finished.
      # @see #state
      def closed? = CLOSED_STATES.include?(@state.value)

      # @return [Boolean] Whether the dispatcher is in its `:running` state.
      # @see #state
      def alive? = @state.value == :running

      # @api private
      def inspect_with(inspector)
        super do
          external = Internal::Storage[self]
          inspector.attribute(:state, state)
          inspector.attribute(:backend, @backend)
          inspector.attribute(:external_scheduler, external) if external && !external.is_a?(Internal::FiberScheduler)
          inspector.attribute(:local, local?) if @owner.value
          yield if block_given?
        end
      end

      protected

      # @api private
      def set_scheduler!(expected_state = :initialized, scheduler: nil)
        setup_owner(expected_state)
        scheduler             ||= @constructor&.call || Internal::FiberScheduler.new(backend: @backend)
        register                = Internal::Storage.store_if_absent(self.class) { Internal::Storage.new }
        register[scheduler]     = self
        Internal::Storage[self] = scheduler
        Fiber.set_scheduler(scheduler) unless Fiber.scheduler.equal?(scheduler)
        runnable_count = :farce_runnable_count if @pool_worker && scheduler.respond_to?(:farce_runnable_count)
        scheduler.fiber do
          dispatch(scheduler, runnable_count) do |task|
            if @pool_worker
              scheduler.fiber(&task.to_proc(@pool_worker))
            else
              scheduler.fiber(&task)
            end
          end
        end
      rescue Internal::SchedulerLifecycle::Cancelled
        raise
      rescue Exception => e # rubocop:disable Lint/RescueException
        unless @state.value == :error
          @error.value = Envelope.new(e)
          @state.value = :error
        end
        raise
      end

      private

      def enqueue_task(non_block, *args, mode: :smart, auto_local: true, timeout: nil, &block)
        raise SchedulerClosedError, "cannot schedule task on a closed scheduler" if closed?

        raise LocalJumpError, "Cannot schedule without a block" unless block

        deadline = scheduling_deadline(timeout)
        task     = prepare_task(args, block, mode, auto_local, timeout: Clock.remaining(deadline))
        return unless task
        return unless non_block ? @queue.try_push(task) : @queue.push(task, timeout: Clock.remaining(deadline))
        self
      rescue ClosedQueueError
        raise unless closed?
        raise SchedulerClosedError, "cannot schedule task on a closed scheduler"
      end

      def new_queue(capacity:) = Internal::Queue.new(capacity:)

      def prepare_task(args, block, mode, auto_local, timeout: nil)
        if auto_local
          owner = @owner.wait_until_non_nil(timeout:)
          raise SchedulerClosedError, "cannot schedule task on a closed scheduler" if closed?
          return unless owner
          mode = :local if owner == Ractor.current
        elsif mode == :local && (owner = @owner.value) && owner != Ractor.current
          raise Ractor::IsolationError, "cannot schedule local task outside the owning Ractor"
        end

        mode == :local ?
          Envelope::Local.new(args.any? ? -> { block.call(*args) } : block) :
          Internal::ScheduledTask.new(args, block, mode)
      end

      def prepare_constructor(constructor)
        return constructor if !constructor || Ractor.shareable?(constructor)
        Ractor.shareable_proc(&constructor)
      end

      def launch_callback = Ractor.shareable_proc { _1.__send__(:launch!, _3, _2) }

      def launch!(name, priority)
        Thread.current.name     = name if name
        Thread.current.priority = priority if priority

        if Fiber.respond_to?(:set_scheduler)
          begin
            set_scheduler!(:launching)
          ensure
            Fiber.set_scheduler(nil) if Fiber.scheduler
          end
        else
          setup_owner(:launching)
          Internal.with_scheduler_thread_group do |group|
            group.add(Thread.current)
            dispatch do |task|
              callback = @pool_worker ? task.to_proc(@pool_worker) : task.to_proc
              group.add(Thread.new(&callback))
            end
            group.list.each { it.join unless it.equal?(Thread.current) }
          end
        end
      end

      def setup_owner(expected_state)
        raise "Scheduler may not be reused" unless @state.compare_and_set(expected_state, :setup)
        self.owner = Ractor.current
      end

      def wake_dispatcher
        # A full queue already guarantees that the dispatcher will wake and observe the closing state.
        @queue.try_push(nil)
      rescue ClosedQueueError
        nil
      end

      def dispatch(scheduler = nil, runnable_count = nil)
        failure = nil
        @state.compare_and_set(:setup, :running)
        while keep_processing?
          if @pool_worker
            settings = @pool_worker.settings
            settings = @pool_worker.wait_for_admission(scheduler, runnable_count, settings)
            break unless settings
          end
          timed_out = false
          task = if @pool_worker
                   @queue.pop_interruptible(settings, settings.shrink_after) { timed_out = true }
                 else
                   @queue.pop { timed_out = true }
                 end
          if timed_out
            break if @pool_worker&.retire?(expected: settings)
            next
          end
          next unless task
          task = task.value if task.is_a?(Envelope)
          if task
            @pool_worker&.task_started(settings)
            yield task
          end
        end
        @queue.close if @queue_owner
      rescue Internal::SchedulerLifecycle::Cancelled => e
        # Shutdown cancellation must not create envelope ports in a terminating Ractor.
        failure = e
        raise
      rescue ClosedQueueError
        raise unless @pool_worker || closed?
      rescue Exception => e # rubocop:disable Lint/RescueException
        failure = e
        @state.value = :error
        @error.value = Envelope.new(e)
        raise
      ensure
        @pool_worker&.stopped(failure)
        # make sure we're in a closed state
        unless @state.compare_and_set(:closing, :closed)
          state = @state.value
          @state.compare_and_set(state, :closed) unless CLOSED_STATES.include?(state)
        end
      end

      def next_task
        task = @queue.pop
        return task unless task.is_a?(Envelope)
        task.value
      end

      def keep_processing?
        case @state.value
        when :running, :setup then true
        when :closing         then @queue.size.positive?
        else false
        end
      end
    end
  end

  module FiberExtension
    Fiber.singleton_class.prepend(self) if Fiber.respond_to?(:set_scheduler)
    def set_scheduler(scheduler) # rubocop:disable Naming/AccessorMethodName
      return super unless scheduler.is_a?(Farce::Abstract::Scheduler)
      scheduler.__send__(:set_scheduler!)
    end
  end

  private_constant :FiberExtension
end
