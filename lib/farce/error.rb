# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

begin
  require "weakref"
rescue LoadError => e
  raise e unless e.path == "weakref"
end

module Farce
  # Raised when an operation cannot proceed because a queue is closed.
  ClosedQueueError = Class.new(::ClosedQueueError)

  # Raised when a push cannot proceed because a queue is sealed.
  SealedQueueError = Class.new(ClosedQueueError)

  # Raised when attempting to schedule a task on a closed scheduler.
  SchedulerClosedError = Class.new(StandardError)

  # Raised when attempting to schedule a task on a closed pool.
  PoolClosedError = Class.new(SchedulerClosedError)

  # Raised when a weak reference is no longer valid because the referenced object has been garbage collected.
  WeakRefError = Class.new(defined?(::WeakRef::RefError) ? ::WeakRef::RefError : StandardError)
end
