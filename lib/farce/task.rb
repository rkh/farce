# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A unit of work that executes once and retains its result or failure.
  #
  # ```ruby
  # # You can create and schedule a task with one call:
  # task = Farce::Task.schedule { 1 + 2 }
  # task.value # => 3
  #
  # # There is also a shorthand for running a task on the global Ractor pool:
  # task = Farce::Task.in_parallel { sleep 1 }
  # task.join
  # task.alive? # => false
  #
  # # schedule accepts a custom scheduler:
  # scheduler = Farce::Scheduler.create
  # task      = Farce::Task.schedule(scheduler:) { 1 + 2 }
  #
  # # or alternatively you can manually create a task and hand it to the scheduler
  # task = Farce::Task.new { 1 + 2 }
  # scheduler.schedule(&task)
  #
  # # or execute it manually
  # task = Farce::Task.new { Ractor.current.name.upcase }
  # Ractor.new(task, name: "Herbert") { it.call }
  # task.value # => "HERBERT"
  # ```
  class Task
    include Abstract::Value
    include Internal::Freeze::Delegated
    include Internal::MarshalSupport::Reject

    # Raised when an operation is attempted on a task that is in an incorrect state.
    InvalidStateError = Class.new(RuntimeError)

    # @!macro [new] task_schedule
    #   @!macro modes
    #   @param args [Array] the arguments to pass to the task
    #   @param mode [Symbol] the mode for arguments and the successful result
    #     Arguments can be overridden by {#add_argument}.
    #   @yield [*args] the block to execute with the given arguments
    #   @yieldparam args [Array] the arguments passed to the block
    #   @yieldreturn [Object] the result of the block execution, will become the task's {#value}
    #   @raise ArgumentError if the provided mode is invalid
    #   @raise LocalJumpError if no callback is provided

    # @overload in_parallel(*args, mode: :smart)
    #   Creates a task and schedules it for execution on the {Farce.in_parallel globally shared executor pool}.
    #   @!macro task_schedule
    #   @return [Task] the created task
    def self.in_parallel(*, **, &) = enqueue(false, Farce.in_parallel, *, auto_local: false, **, &)

    # @overload on_main(*args, mode: :smart, auto_local: true)
    #   Creates a task and schedules it for execution on the {Farce.on_main main scheduler}.
    #   If `auto_local` is true (default), `mode` will be set to `:local` if the method is called from the main Ractor.
    #
    #   @!macro task_schedule
    #   @param auto_local [Boolean] whether to automatically switch to local mode if called from the main Ractor
    #   @return [Task] the created task
    def self.on_main(*, **, &) = enqueue(false, Farce.on_main, *, **, &)

    # @overload schedule(*args, mode: :smart, auto_local: true, scheduler: nil, &)
    #   Creates a task and schedules it for execution.
    #   A scheduler may optionally be provided.
    #
    #   If no scheduler is provided, then it will look for a Ractor-local scheduler if mode is `:local` or `auto_local`
    #   is true. If none is found, one will be created automatically if `:mode` is `:local`, otherwise the
    #   {Farce.in_parallel globally shared executor pool} will be used.
    #
    #   The scheduler may be a {Abstract::Executor executor}, or a Fiber scheduler.
    #
    #   @!macro task_schedule
    #   @param scheduler [Abstract::Executor, Fiber::Scheduler, nil] the scheduler to use for execution
    #   @return [Task] the created task
    def self.schedule(*, scheduler: nil, **, &) = enqueue(false, scheduler, *, **, &)

    # @overload try_schedule(*args, mode: :smart, auto_local: true, scheduler: nil, &)
    #   Creates a task and attempts to schedule it for execution.
    #
    #   Behaves exactly like {.schedule}, except it uses {Abstract::Executor#try_schedule} instead of
    #   {Abstract::Executor#schedule} if the scheduler is an executor, and that it returns `nil` if it fails to
    #   schedule the task.
    #
    #   @!macro task_schedule
    #   @return [Task, nil] the created task, or `nil` if it failed to schedule
    def self.try_schedule(*, scheduler: nil, **, &) = enqueue(true, scheduler, *, **, &)

    # @api private
    def self.enqueue(non_block, scheduler, *, mode: :smart, auto_local: true, &) # :nodoc:
      unless scheduler
        scheduler = Internal.local_scheduler(create: mode == :local) if auto_local || mode == :local
        unless scheduler
          scheduler  = Internal::ParallelScheduler
          auto_local = false
        end
      end

      if scheduler.is_a?(Abstract::Executor)
        mode = :local if auto_local && scheduler.local?(wait: false)
        task = new(*, mode:, &)

        if non_block
          return unless scheduler.try_schedule(mode:, auto_local: false, &task)
        else
          scheduler.schedule(mode:, auto_local: false, &task)
        end
      else
        task = new(*, mode: :local, &)
        scheduler.fiber(&task)
      end

      task
    end
    private_class_method :enqueue

    # @return [Symbol] the default mode used for task arguments and the return value
    attr_reader :mode

    # Creates a new task with the given arguments and callback.
    #
    # This does not schedule the task for execution, nor does it associate it with any executor.
    #
    # In fact, the task object itself is a proc-like object, that can be {call called} like a regular proc,
    # but will track its execution state and result.
    #
    # @example Using a Task without an Executor
    #   task = Farce::Task.new(1, 2) { |a, b| a + b }
    #
    #   task.alive?       # => true
    #   task.call == task # => true
    #   task.alive?       # => false
    #   task.value        # => 3
    #
    # @example Passing a task to an executor
    #   task = Farce::Task.new { puts "Hello, world!" }
    #   Farce.in_parallel(&task)
    #   task.join # waits for the task to complete
    #
    # @!macro task_schedule
    def initialize(*args, mode: :smart, &callback)
      raise ArgumentError, "invalid mode: #{mode}" unless MODES.include?(mode)
      raise LocalJumpError, "no callback provided" unless block_given?

      @mode   = mode
      @ractor = Strict::Atom.new
      @state  = Strict::Atom.new(:initialized)

      if mode == :local
        @arguments    = args
        @callback     = callback
        @manager      = nil
        @ractor.value = Ractor.current
        @result       = Unshared::Atom.new
      else
        @arguments = Strict::Vector.new
        @callback  = Ractor.shareable?(callback) ? callback : Ractor.shareable_proc(&callback)
        @manager   = ModeManager.new(mode: mode)
        @result    = Strict::Atom.new
        args.each { add_argument(it) }
      end

      __freeze__
    end

    # Adds an argument to the task.
    # Can only be called before the task is frozen and before {#call} is invoked.
    #
    # Allows for arguments to use different modes than the return value (or other arguments).
    # Mode is ignored for {#local? local} tasks.
    #
    # For non-local tasks, `mode` may only be set to `:local` for arguments added by the Ractor that will
    # {#call execute} the task.
    #
    # @example A task using `move` for the return value, but `copy` for its argument
    #   task = Farce::Task.new(mode: :move) { |arg| arg.upcase }
    #   task.add_argument("hello", mode: :copy)
    #   Farce.in_parallel(&task)
    #   task.value # => "HELLO"
    #
    # @param argument [BasicObject] the argument to add to the task
    # @param mode [Symbol, nil] the mode to use for the argument, or `nil` to use the task's default mode
    # @raise ArgumentError if the provided mode is invalid
    # @raise FrozenError if the task has already been frozen or called
    # @raise InvalidStateError if trying to add a local argument from more than one ractor
    # @return [self] the task itself, for chaining
    def add_argument(argument, mode: nil)
      check_frozen!

      unless local?
        raise ArgumentError, "invalid mode: #{mode}" unless mode.nil? || MODES.include?(mode)
        raise InvalidStateError, "cannot add local argument to a non-local task" if mode == :local && !claim_for_ractor?
        argument = @manager.wrap(argument, mode:)
      end

      @arguments << argument
      self
    end

    alias << add_argument

    # @return [Boolean] whether the task is currently alive (initialized or running)
    def alive? = alive_state?(@state.value)

    # Executes the task by invoking its callback with the added arguments.
    # @raise InvalidStateError if the task has already been claimed by another ractor or has already been called
    # @return [self] the task itself, for chaining
    def call
      raise InvalidStateError, "task already claimed by another ractor" unless claim_for_ractor?
      raise InvalidStateError, "call may only be called once" unless @state.compare_and_set(:initialized, :running)
      begin
        arguments     = local? ? @arguments.freeze : @arguments.freeze.to_a.map! { @manager.unwrap(it) }
        result        = @callback.call(*arguments)
        @result.value = local? ? result : @manager.wrap(result)
        @state.value  = :finished
      rescue Exception => e # rubocop:disable Lint/RescueException
        # Every callback failure must release waiters, including ScriptError and SystemExit.
        begin
          @result.value = e
        rescue Ractor::Error
          @result.value = [RuntimeError, -"#{e.class}: #{e.message}", Ractor.make_shareable(e.backtrace)].freeze
        end
        @state.value = :error
      ensure
        if @state.value == :running
          @result.value = [RuntimeError, -"task execution aborted"].freeze
          @state.value  = :error
        end
      end

      self
    end

    # Waits for the task to finish, with an optional timeout.
    # @param timeout [Numeric, nil] the maximum time to wait, or `nil` to wait indefinitely
    # @return [self, nil] the task itself if it finished within the timeout, or `nil` otherwise
    def join(timeout = nil)
      return unless @state.wait_while(timeout:) { alive_state?(it) }
      self
    end

    # @return [Boolean] whether the task is local (i.e., its mode is `:local`)
    def local? = @mode == :local

    # Waits for the task to finish and returns its value, with an optional timeout.
    # If the task raises an error, it will be propagated.
    #
    # @param timeout [Numeric, nil] the maximum time to wait, or `nil` to wait indefinitely
    # @return [BasicObject, nil]
    #   the value returned by the task's callback, or `nil` if the task did not finish within the timeout
    # @raise Exception if the task raises an error
    # @raise RuntimeError with the original class, message, and backtrace if the exception cannot be shared
    # @raise RuntimeError if execution is aborted before producing a result or exception
    def value(timeout = nil)
      case @state.wait_while(timeout:) { alive_state?(it) }
      when :finished then local? ? @result.value : @manager.unwrap(@result.value)
      when :error    then raise(*@result.value)
      end
    end

    # Converts the task to a Proc object.
    # If the task is Ractor-shareable, then so is the returned Proc.
    # @return [Proc] a Proc that calls the task's `call` method
    def to_proc
      return method(:call).to_proc if local?
      task = self
      Ractor.make_shareable(-> { task.call })
    end

    private

    def alive_state?(state) = state == :initialized || state == :running

    def claim_for_ractor?
      current_ractor = Ractor.current
      @ractor.compare_and_set(nil, current_ractor)
      @ractor.value == current_ractor
    end

    define_method(:__freeze__, Kernel.instance_method(:freeze))
    def freeze_backend = @arguments
  end
end
