# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Unshared
    # A task scheduler that runs work within its creating Ractor.
    #
    # Use {.create} to start a background thread, or install an instance with
    # `Fiber.set_scheduler` on the current thread. Tasks retain their blocks and
    # argument references. The scheduler cannot be copied or moved to another Ractor.
    #
    # `auto_local: true` ignores `mode`. With `auto_local: false`, only `:local`
    # and smart modes are accepted. All accepted modes keep tasks local.
    #
    # @example Run tasks with captured local state
    #   results   = Farce::Unshared::Queue.new
    #   scheduler = Farce::Unshared::Scheduler.create
    #   scheduler.schedule { results.push(:done) }
    #   results.pop # => :done
    #   scheduler.close
    #
    # @!method schedule(*args, mode: :smart, auto_local: true)
    #   Enqueue a task while retaining its block and argument references.
    #   `mode` is ignored when `auto_local` is true. Otherwise, only local and
    #   smart modes are accepted.
    #   @param (see Farce::Abstract::Executor#schedule)
    #   @return [self]
    class Scheduler < Abstract::Scheduler
      include Unshareable
      include Internal::LocalExecutorMethods

      # Start a worker thread in this Ractor. Returns the running scheduler.
      # Additional options and the block are forwarded to {#initialize}.
      # @param executor [Class, nil] Thread or a custom executor that stays in this Ractor.
      # @param name [String, nil] Optional worker name.
      # @param priority [Integer, nil] Optional worker thread priority.
      # @yieldreturn [Object] Fiber scheduler to install in the worker.
      # @return [Scheduler]
      def self.create(executor = Thread, name: nil, priority: nil, **, &) = super

      # Create a scheduler without starting a worker.
      # A constructor block builds the fiber scheduler when launched or installed.
      # It may capture objects from this Ractor.
      #
      # @overload initialize(capacity: 1024, backend: Farce.config.io_backend, &constructor)
      #   @param capacity [Integer, nil] Pending-task capacity, or nil for an unbounded queue.
      #   @param backend [Symbol] IO backend for the built-in scheduler.
      #   @yieldreturn [Object] Fiber scheduler to install in the worker.
      def initialize(...)
        super
        self.owner = Ractor.current
      end

      # Start dispatching tasks in a new thread or a custom executor in this Ractor.
      # Rejects Ractor executors before changing the scheduler's state.
      # @param executor [Class, nil] Thread or a custom executor that stays in this Ractor.
      # @param name [String, nil] Optional worker name.
      # @param priority [Integer, nil] Optional worker thread priority.
      # @return [Thread, Object] The worker.
      # @raise [ArgumentError] If a Ractor executor is supplied.
      def launch(executor = Thread, name: nil, priority: nil)
        raise ArgumentError, "Unshared schedulers cannot launch Ractor workers" if executor && executor <= Ractor
        super(executor || Thread, name:, priority:)
      end

      # @raise [ArgumentError] Unshared schedulers cannot launch Ractor workers.
      def launch_ractor(...) = launch(Ractor, ...)

      # @param value [Ractor] The creating Ractor.
      # @raise [ArgumentError] If another Ractor is supplied or the assigned owner changes.
      def owner=(value)
        raise ArgumentError, "owner must be the current Ractor" unless value == Ractor.current
        super
      end

      private

      def prepare_constructor(constructor) = constructor
      def new_queue(capacity:)             = Internal::UnsharedQueue.new(capacity:)
      def launch_callback                  = ->(_scheduler, priority, name) { launch!(name, priority) }

      def prepare_task(args, block, mode, auto_local)
        validate_local_mode(mode, auto_local)
        Internal::LocalScheduledTask.new(args, block)
      end
    end
  end
end
