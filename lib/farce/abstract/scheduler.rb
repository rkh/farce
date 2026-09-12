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
    end
  end
end
