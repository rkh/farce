# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A scheduler that starts a new thread for each scheduled task. Executes synchronous tasks inline.
  # Creating an instance starts no threads. Blocks and arguments stay local to the caller.
  # Tasks are not tracked, and closing this stateless scheduler has no effect.
  class ThreadScheduler < Farce::Abstract::Scheduler
    include Shareable::Immutable
    include Internal::Inspect

    def initialize(&factory)
      @factory = factory
      super()
    end

    # Starts a thread in the caller's Ractor, preserving the block and arguments.
    #
    # @overload schedule(*args, **options)
    #   @param args [Array<Object>] Arguments passed to the block.
    #   @param options [Hash] Scheduler options are ignored. All tasks use local arguments.
    #   @yield [*args] The task to run.
    #   @return [self]
    def schedule(*, **, &)
      raise LocalJumpError, "Cannot schedule without a block" unless block_given?
      @factory ? @factory.call(*, &) : Thread.new(*, &)
      self
    end

    # Runs the block on the caller's thread and fiber. Exceptions propagate to the caller.
    #
    # @overload execute(*args, **options)
    #   @param args [Array<Object>] Arguments passed to the block.
    #   @param options [Hash] Scheduler options are ignored. All tasks use local arguments.
    #   @yield [*args] The task to run.
    #   @return [self]
    def execute(*, **)
      raise LocalJumpError, "Cannot yield without a block" unless block_given?
      yield(*)
      self
    end

    # @return [self] Does not wait for or stop task threads.
    def close = self

    # @return [false] This stateless scheduler is always available.
    def closed? = false

    # @return [Symbol] Always `:running`.
    def state = :running

    # @param wait [Boolean] Ignored because tasks always run in the caller's Ractor.
    # @return [true]
    def local?(wait: true) = true # rubocop:disable Lint/UnusedMethodArgument
  end
end
