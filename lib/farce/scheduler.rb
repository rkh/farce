# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A Ractor-shareable task scheduler.
  #
  # Tasks run as fibers using a fiber scheduler, or as threads when the Ruby implementation
  # doesn't support Fiber schedulers (ie TruffleRuby).
  #
  # It supports any existing Fiber scheduler, including Async and CarbonFiber, but
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
  class Scheduler < Farce::Abstract::Scheduler
    include Shareable::Unfreezable
  end
end
