# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract A shared super class for all scheduler implementations.
    #
    # @!method schedule(*args, mode: :copy, auto_local: true)
    #   @abstract This method must be implemented by concrete scheduler subclasses.
    #
    #   Schedules a block for execution.
    #   What actually happens depends on the concrete scheduler implementation.
    #   Some schedulers may ignore the `auto_local` option. Some might treat every mode as `:local`.
    #
    #   The scheduler may choose to block until the task has been executed, but most will add it to a queue of pending
    #   tasks, only blocking when that queue's capacity has been reached.
    #
    #   @!macro modes
    #
    #   @param args [Array]
    #     Arguments to pass to the scheduled block.
    #     May be handled according to `mode`.
    #
    #   @param mode [Symbol]
    #     The mode in which to schedule the task. Defaults to `:copy`.
    #     May be ignored by some schedulers.
    #
    #   @param auto_local [Boolean]
    #     Whether to automatically use a local mode when possible. Defaults to `true`.
    #     May be ignored by some schedulers.
    #
    #   @yield [*args] The block to be executed by the scheduler.
    #   @yieldparam args [Array] The arguments passed to the block.
    #   @yieldreceiver [BasicObject, nil]
    #     Local mode will not touch the block's binding (self stays the same), but other modes may change it to `nil`.
    #
    #   @return [self]
    #
    # @!method close
    #   @abstract This method must be implemented by concrete scheduler subclasses.
    #   Closes the scheduler, releasing any resources it holds.
    #   Once closed, the scheduler cannot be used to schedule new tasks.
    #   Will drain any pending tasks before fully closing. If tasks are running indefinitely, it may block.
    #   @return [self]
    #
    # @!method closed?
    #   @abstract This method must be implemented by concrete scheduler subclasses.
    #   @return [Boolean] Whether the scheduler is closed.
    #
    # @!method state
    #   @abstract This method must be implemented by concrete scheduler subclasses.
    #   @return [Symbol]
    #     The current state of the scheduler.
    #
    #     Common states include:
    #     * `:initialized`, `:launching` and `:setup` for the setup phase.
    #     * `:running` for the execution phase.
    #     * `:closing`, `:closed`, and `:error` for the termination phase.
    #
    #     Not all schedulers will implement every state.
    #
    # @!method ractor_safe?
    #   @abstract Schedulers should include {Shareable} or {Unshareable}, which implement this method.
    #   @return [Boolean] Whether the scheduler is safe to use across Ractors.
    class Scheduler
      # An error that occurred during the scheduler's operation, if any.
      # This is primarily for scheduling errors, not execution errors.
      # You can check this if the {#state} is `:error`.
      def error = nil

      # @param wait [Boolean] Whether to wait for the owner to be non-nil before checking if the scheduler is local.
      # @return [Boolean] Whether the scheduler is local for the current Ractor.
      def local?(wait: true) = false # rubocop:disable Lint/UnusedMethodArgument

      # Like {#schedule}, with two differences:
      # 1. If {#local?} returns true, and it would run in local mode (either due to `auto_local` or explicitly set
      #    `mode: :local`), it executes the block directly without enqueuing it.
      # 2. It blocks until the block has been executed, either immediately in local mode or after being scheduled.
      #
      # @param (see #schedule)
      # @return [self]
      def execute(*, mode: :copy, auto_local: true, &callback)
        raise LocalJumpError, "Cannot yield without a block" unless block_given?
        raise SchedulerClosedError, "cannot execute task on a closed scheduler" if closed?

        if (auto_local || mode == :local) && local?
          raise SchedulerClosedError, "cannot execute task on a closed scheduler" if closed?
          yield(*)
          return self
        end

        ran      = Flag.new(false)
        signal   = Signal.new
        callback = Ractor.shareable_proc(&callback) unless Ractor.shareable?(callback)

        schedule(callback, ran, signal, *, mode:, auto_local:) do |callback, ran, signal, *args|
          callback.call(*args)
        ensure
          ran.set
          signal.broadcast
        end

        signal.wait_until { ran.value }
        self
      end
    end
  end
end
