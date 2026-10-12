# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Unshared
    # An elastic pool of thread workers within one Ractor.
    #
    # Uses the same scaling and fiber schedulers as {Farce::Pool}. Tasks keep their
    # blocks and argument references. `auto_local: true` ignores `mode`. With
    # `auto_local: false`, only `:local` and smart modes are accepted.
    # The pool cannot be copied or moved to another Ractor.
    # A scheduler constructor may capture objects from this Ractor.
    #
    # @example Submit work using local state
    #   results = Farce::Unshared::Queue.new
    #   pool    = Farce::Unshared::Pool.new(max_size: 2)
    #   pool.schedule { results.push(:done) }
    #   results.pop # => :done
    #   pool.close
    class Pool < Abstract::Pool
      include Unshareable
      include Internal::LocalExecutorMethods

      private

      def publish_pool                     = pin_unshareable
      def prepare_constructor(constructor) = constructor
      def new_queue(capacity:)             = Internal::UnsharedQueue.new(capacity:, track_age: true)
      def new_worker                       = Internal::UnsharedPoolWorker.new(self)
      def new_scheduler(**, &)             = Scheduler.new(**, &)
      def launch_scheduler(scheduler)      = scheduler.launch_thread

      def prepare_task(args, block, mode, auto_local)
        validate_local_mode(mode, auto_local)
        Internal::LocalScheduledTask.new(args, block)
      end

      def schedule_scaler(started, delay = @grow_after)
        Internal::ThreadPoolSupervisor.current.schedule(self, started, delay)
      end
    end
  end
end
