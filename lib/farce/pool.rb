# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A dynamically sized pool of Ractor schedulers.
  #
  # Tasks wait in one shared queue. An empty pool starts its first worker immediately
  # when work arrives. A task that remains queued for `grow_after`
  # causes the pool to add a worker until `max_size` is reached. Workers above
  # `min_size` retire after `shrink_after` without queued or running work.
  # By default, the pool starts with no workers and can shrink back to zero.
  #
  # Most importantly, it exposes a {#schedule} method compatible with {Scheduler#schedule}.
  #
  # @example
  #   # Create a new pool
  #   pool = Farce::Pool.new
  #
  #   # Schedule some work on the pool.
  #   pool.schedule do
  #     # The work runs in a non-blocking fiber, multiple tasks can run concurrently even on the same worker.
  #     loop do
  #       sleep 5
  #       MyClass.recurring_work
  #     end
  #   end
  #
  # @example Custom Fiber scheduler
  #   require "farce"
  #   require "carbon_fiber"
  #
  #   # At least two Ractors, up to four. Launch a new one if a task waits longer than 100 milliseconds.
  #   # Use the fiber scheduler from the carbon_fiber gem.
  #   pool = Farce::Pool.new(min_size: 2, max_size: 4, grow_after: 0.1) { CarbonFiber::Scheduler.new }
  #
  #   # Schedule some work
  #   pool.schedule { MyClass.do_something }
  class Pool < Farce::Abstract::Pool
    include Shareable::Unfreezable

    private def publish_pool = publish_shareable
  end
end
