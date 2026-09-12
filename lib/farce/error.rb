# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # Raised when an operation cannot proceed because a queue is closed.
  class ClosedQueueError < ::ClosedQueueError
  end

  # Raised when a push cannot proceed because a queue is sealed.
  class SealedQueueError < ClosedQueueError
  end

  # Raised when attempting to schedule a task on a closed scheduler.
  class SchedulerClosedError < StandardError
  end

  # Raised when attempting to schedule a task on a closed pool.
  class PoolClosedError < SchedulerClosedError
  end
end
