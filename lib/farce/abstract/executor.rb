# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # A task executor that can submit work or wait for it to finish.
    #
    # {#schedule} submits a task. {#execute} waits for the task to finish and may
    # run it directly when execution is local. Concrete executors decide where
    # tasks run and how their arguments are transferred.
    #
    # @abstract Use a scheduler or pool class.
    #
    # @!method schedule(*args, mode: :smart, auto_local: true, timeout: nil)
    #   @abstract This method must be implemented by concrete executor subclasses.
    #
    #   Schedules a block for execution.
    #   What actually happens depends on the concrete executor implementation.
    #   Some executors may ignore the `auto_local` option. Some might treat every mode as `:local`.
    #
    #   The executor may choose to block until the task has been executed, but most will add it to a queue of pending
    #   tasks, only blocking when that queue's capacity has been reached.
    #
    #   @!macro modes
    #
    #   @param args [Array]
    #     Arguments to pass to the scheduled block.
    #     May be handled according to `mode`.
    #
    #   @param mode [Symbol]
    #     The mode in which to schedule the task. Defaults to `:smart`.
    #     May be ignored by some executors.
    #
    #   @param auto_local [Boolean]
    #     Whether to automatically use a local mode when possible. Defaults to `true`.
    #     May be ignored by some executors.
    #
    #   @param timeout [Numeric, nil]
    #     Maximum seconds to wait for ownership and queue space. Nil waits indefinitely.
    #     Zero only submits if no waiting is needed. Must be finite and non-negative.
    #     An expired attempt returns `nil` and does not enqueue the task.
    #     This does not limit task execution time. Executors without a queue may ignore it.
    #
    #   @yield [*args] The block to be executed by the scheduler.
    #   @yieldparam args [Array] The arguments passed to the block.
    #   @yieldreceiver [BasicObject, nil]
    #     Local mode will not touch the block's binding (self stays the same), but other modes may change it to `nil`.
    #
    #   @return [self, nil] self when submitted, or nil when the scheduling timeout expires.
    #
    # @!method close
    #   @abstract This method must be implemented by concrete executor subclasses.
    #   Closes the executor, releasing any resources it holds.
    #   Once closed, the executor cannot be used to schedule new tasks.
    #   Will drain any pending tasks before fully closing. If tasks are running indefinitely, it may block.
    #   @return [self]
    #
    # @!method closed?
    #   @abstract This method must be implemented by concrete executor subclasses.
    #   @return [Boolean] Whether the executor is closed.
    #
    # @!method state
    #   @abstract This method must be implemented by concrete executor subclasses.
    #   @return [Symbol]
    #     The current state of the executor.
    #
    #     Common states include:
    #     * `:initialized`, `:launching` and `:setup` for the setup phase.
    #     * `:running` for the execution phase.
    #     * `:closing`, `:closed`, and `:error` for the termination phase.
    #
    #     Not all executors will implement every state.
    #
    # @!method ractor_shareable?
    #   @abstract Executors should include {Shareable} or {Unshareable}, which implement this method.
    #   @return [Boolean] Whether the executor is safe to use across Ractors.
    class Executor
      include Internal::Noncopyable

      # An error that occurred during the executor's operation, if any.
      # This is primarily for scheduling errors, not execution errors.
      # You can check this if the {#state} is `:error`.
      def error = nil

      # @param wait [Boolean] Whether to wait for the owner to be non-nil before checking if the executor is local.
      # @return [Boolean] Whether the executor is local for the current Ractor.
      def local?(wait: true) = false # rubocop:disable Lint/UnusedMethodArgument

      # Attempts to submit a task. Queue-based executors return `nil` when full
      # instead of waiting for space. Other executors behave like {#schedule}.
      #
      # @param args (see #schedule)
      # @param mode (see #schedule)
      # @param auto_local (see #schedule)
      # @return [self, nil] self when submitted, or nil when the queue is full.
      def try_schedule(...) = schedule(...)

      # Closes the executor in every scope.
      # For executors without scopes, this behaves like {#close}.
      #
      # @return [self]
      def close_all = close

      # Like {#schedule}, with two differences:
      # 1. If {#local?} returns true, and it would run in local mode (either due to `auto_local` or explicitly set
      #    `mode: :local`), it executes the block directly without enqueuing it.
      # 2. It blocks until the block has been executed, either immediately in local mode or after being scheduled.
      # A `timeout` only limits scheduling waits. Once submitted, this waits for completion without a timeout.
      #
      # @param (see #schedule)
      # @return [self, nil] self after execution, or nil when the scheduling timeout expires.
      def execute(*, mode: :smart, auto_local: true, timeout: nil, &callback)
        raise LocalJumpError, "Cannot yield without a block" unless block_given?
        raise SchedulerClosedError, "cannot execute task on a closed scheduler" if closed?

        deadline = scheduling_deadline(timeout)
        if (auto_local || mode == :local) && local?(wait: timeout.nil?)
          raise SchedulerClosedError, "cannot execute task on a closed scheduler" if closed?
          yield(*)
          return self
        end

        ran      = Farce::Flag.new(false)
        signal   = Signal.new
        callback = Ractor.shareable_proc(&callback) unless Ractor.shareable?(callback)

        submitted = schedule(callback, ran, signal, *, mode:, auto_local:,
          timeout: Clock.remaining(deadline)) do |callback, ran, signal, *args|
          callback.call(*args)
        ensure
          ran.set
          signal.broadcast
        end
        return unless submitted

        signal.wait_until { ran.value }
        self
      end

      private

      def scheduling_deadline(timeout)
        return if timeout.nil?
        timeout = Float(timeout)
        unless timeout.finite? && !timeout.negative?
          raise ArgumentError, "timeout must be a finite, non-negative number or nil"
        end
        Clock.timeout(timeout)
      end
    end
  end
end
