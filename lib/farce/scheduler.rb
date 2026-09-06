# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A Ractor-shareable task scheduler.
  #
  # Tasks run as fibers using a fiber scheduler, or as threads when the Ruby implementation
  # doesn't support Fiber schedulers (ie TruffleRuby).
  #
  # If supports any existing Fiber scheduler, including Async and CarbonFiber, but
  # can also be used as a Fiber scheduler itself.
  #
  # Use {.create} to start a worker, or construct an instance and install it with
  # `Fiber.set_scheduler` on the current thread. A scheduler can only be launched
  # or installed once.
  #
  # It will keep the fiber scheduler alive until it is explicitly closed.
  # Closing a scheduler stops new submissions through {#schedule}. The underlying
  # fiber scheduler has its own lifecycle: draining fibers may still spawn child
  # fibers with `Fiber.schedule` while it is closing.
  #
  # @example Submit arguments to a worker
  #   # Runs a scheduler in a background Ractor/Thread
  #   scheduler = Farce::Scheduler.create
  #   scheduler.schedule("hello") { |message| puts message }
  #
  # @example Using Farce::Scheduler as a Fiber scheduler
  #   scheduler = Farce::Scheduler.new
  #   Fiber.set_scheduler(scheduler)
  #   Fiber.schedule { puts "Hello from the scheduler!" }
  class Scheduler
    include Shareable

    # Raised when attempting to schedule a task on a closed scheduler.
    class ClosedError < StandardError
    end

    # A wrapper around a proc that carries arguments with it, possibly wrapping the arguments in an Envelope.
    class Task
      include Shareable

      MANAGER = ModeManager.new

      def initialize(args, block, mode)
        @block    = Ractor.shareable_proc(&block)
        @unwrap   = false
        @args     = args.map! do |arg|
          wrapped = MANAGER.wrap(arg, mode:)
          @unwrap = true if MANAGER.managed_envelope?(wrapped)
          wrapped
        end.freeze
        super()
      end

      def to_proc
        return -> { @block.call(*@args) } unless @unwrap
        -> { @block.call(*@args.map { |arg| MANAGER.unwrap(arg) }) }
      end
    end

    CLOSED_STATES = Set[:closed, :closing, :error].freeze
    private_constant :Task, :CLOSED_STATES

    # Returns a Farce scheduler for the current thread's installed fiber scheduler.
    # Returns `nil` when no fiber scheduler is installed.
    #
    # Creates and installs a wrapper when necessary, starting its dispatcher on
    # that scheduler. Returns `nil` when no fiber scheduler is installed.
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
      return unless scheduler = Fiber.scheduler
      register = Internal::Storage.store_if_absent(self) { Internal::Storage.new }
      register.store_if_absent(scheduler) do
        wrapper = new(**, external: true)
        wrapper.__send__(:set_scheduler!, scheduler)
        wrapper
      end
    end

    # Creates a new scheduler and starts it in a background ractor, thread, or custom executor.
    #
    # @overload create(executor = nil, name: nil, priority: nil, capacity: 1024, backend: Farce.config.io_backend)
    #   Runs tasks on Farce's built-in fiber scheduler. Use this when you don't
    #   need another library's event loop. The backend option selects its IO driver.
    #
    #   @example
    #     scheduler = Farce::Scheduler.create
    #     scheduler.schedule { puts "Running on the built-in scheduler" }
    #
    #   @param executor [Class, nil] Ractor or Thread; nil selects the runtime default.
    #   @param name [String, nil] Optional worker name.
    #   @param priority [Integer, nil] Optional worker thread priority.
    #   @param capacity [Integer, nil] Pending-task capacity; nil creates an unbounded queue.
    #   @param backend [Symbol] IO backend for the built-in scheduler; defaults to Farce configuration.
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
    #   The block must be Ractor-shareable. Require the library before calling
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
    #   @param capacity [Integer, nil] Pending-task capacity; nil creates an unbounded queue.
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
    #   Uses Farce's built-in fiber scheduler when launched or installed.
    #
    #   @param capacity [Integer, nil] Pending-task capacity; nil creates an unbounded queue.
    #   @param backend [Symbol] IO backend for the built-in scheduler; defaults to Farce configuration.
    #
    # @overload initialize(capacity: 1024, &block)
    #   Uses another library's fiber scheduler while retaining Farce's ability to
    #   accept tasks from other threads and Ractors.
    #
    #   Supply a block that constructs and returns that scheduler. The block runs
    #   once when this handle is launched or installed, in the thread that will
    #   run the tasks, rather than during new. It must be Ractor-shareable.
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
    #   @param capacity [Integer, nil] Pending-task capacity; nil creates an unbounded queue.
    #   @yieldreturn [Object] The fiber scheduler to install when launched or installed.
    def initialize(capacity: 1024, backend: CONFIG.freeze.io_backend, queue: nil, external: false, &)
      @capacity    = capacity ? Integer(capacity) : nil
      @backend     = backend
      @constructor = block_given? ? Ractor.shareable_proc(&) : nil
      @external    = external || block_given?
      @owner       = Internal::Atom.new(nil)
      @state       = Internal::Atom.new(:initialized)
      @error       = Internal::Atom.new
      @queue       = queue || Internal::Queue.new(capacity: @capacity)
      super()
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
      callback   = Ractor.shareable_proc(self: self) { _1.__send__(:launch!, _3, _2) }

      return executor.new(self, priority, name, &callback) unless executor <= Ractor
      executor.new(self, priority, name, name:, &callback)
    rescue Exception => e # rubocop:disable Lint/RescueException
      @state.value = :error
      @error.value = Envelope.new(e)
      raise
    ensure
      # if we return the thread too early, someone could kill it while another threads blocks on a schedule call
      @state.wait_until_changed(:launching)
      @state.wait_until_changed(:setup)
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
    # @!macro modes
    #
    # @param args [Array<Object>] Positional arguments passed to the task block.
    # @param mode [Symbol]
    #   Argument transfer mode: `:copy`, `:move`, `:local`, `:make_shareable`, `:shareable_copy`, or `:raise`.
    #   See {ModeManager#wrap}.
    # @param auto_local [Boolean] Whether to override mode with `:local` in the owning Ractor.
    # @yield [*args] The task to execute.
    # @return [Scheduler] self.
    # @raise [ClosedError] If the handle is closing, closed, or in an error state.
    # @see Ractor.shareable_proc
    def schedule(*args, mode: :copy, auto_local: true, &block)
      raise ClosedError, "cannot schedule task on a closed scheduler" if closed?

      if auto_local
        owner = @owner.wait_until_non_nil
        raise ClosedError, "cannot schedule task on a closed scheduler" if closed?
        mode  = :local if owner == Ractor.current
      end

      task = mode == :local ?
        Envelope::Local.new(args.any? ? -> { block.call(*args) } : block) :
        Task.new(args, block, mode)

      @queue.push(task)
      self
    rescue ClosedQueueError
      raise unless closed?
      raise ClosedError, "cannot schedule task on a closed scheduler"
    end

    # Requests shutdown and rejects further submissions. Repeated calls are harmless.
    # The dispatcher drains queued tasks before closing the queue; this method
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
      wake_dispatcher
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

    private

    def setup(expected_state = :initialized, external_scheduler = nil)
      setup_owner(expected_state)
      scheduler               = external_scheduler || @constructor&.call ||
        Internal::FiberScheduler.new(backend: @backend)
      register                = Internal::Storage.store_if_absent(self.class) { Internal::Storage.new }
      register[scheduler]     = self
      Internal::Storage[self] = scheduler
      Fiber.set_scheduler(scheduler) unless Fiber.scheduler.equal?(scheduler)
      scheduler
    end

    def launch!(name, priority)
      Thread.current.name     = name if name
      Thread.current.priority = priority if priority

      if Fiber.respond_to?(:set_scheduler)
        setup(:launching)
        dispatch { Fiber.schedule(&it) }
      else
        setup_owner(:launching)
        group = ThreadGroup.new
        group.add(Thread.current)

        dispatch { group.add(Thread.new(&it)) }
        group.list.each { it.join unless it.equal?(Thread.current) }
      end
    end

    def set_scheduler!(external_scheduler = nil)
      scheduler = setup(:initialized, external_scheduler)
      scheduler.fiber { dispatch { scheduler.fiber(&it) } }
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

    def dispatch
      @state.compare_and_set(:setup, :running)
      while keep_processing?
        task = @queue.pop
        task = task.value if task.is_a?(Envelope)
        yield task if task
      end
      @queue.close
    rescue Exception => e # rubocop:disable Lint/RescueException
      @state.value = :error
      @error.value = Envelope.new(e)
      raise
    ensure
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

  module FiberExtension
    Fiber.singleton_class.prepend(self) if Fiber.respond_to?(:set_scheduler)
    def set_scheduler(scheduler) # rubocop:disable Naming/AccessorMethodName
      return super unless scheduler.is_a?(Farce::Scheduler)
      scheduler.__send__(:set_scheduler!)
    end
  end

  private_constant :FiberExtension
end
