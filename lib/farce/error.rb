# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # Raised when an operation cannot proceed because a queue is closed.
  ClosedQueueError = Class.new(::ClosedQueueError)

  # Raised when a push cannot proceed because a queue is sealed.
  SealedQueueError = Class.new(ClosedQueueError)

  # Raised when attempting to schedule a task on a closed scheduler.
  SchedulerClosedError = Class.new(StandardError)

  # Raised when attempting to schedule a task on a closed pool.
  PoolClosedError = Class.new(SchedulerClosedError)
end
