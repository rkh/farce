# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/resolv"

module Farce
  module Internal
    # Task admission, timers and shutdown shared by the scheduler implementations.
    module SchedulerLifecycle
      include Farce::Unshareable

      # Prepending bypasses Unshareable's include hook, so remove freeze here.
      def self.prepended(scheduler)
        scheduler.undef_method(:freeze)
      end

      class Cancelled < Exception # rubocop:disable Lint/InheritException
      end

      Timer      = Struct.new(:deadline, :token, :fiber, :error, :active)
      Completion = Struct.new(:token, :value, :error)
      SLOT_COUNT = 64
      private_constant :Timer, :Cancelled, :Completion, :SLOT_COUNT

      def initialize(backend: CONFIG.freeze.io_backend, thread_pool: ThreadPool.current)
        super(backend: backend)
        @owner           = owner_thread
        @root            = Fiber.current
        @fibers          = {}.compare_by_identity
        @timers          = Internal::UnsharedPriorityQueue.new
        @mailbox         = Thread::Queue.new
        @thread_pool     = thread_pool
        @closed          = @closing = @running = @stopping = false
        @suspensions     = @immediate = 0
        @dispatch_budget = dispatch_budget
      rescue Exception # rubocop:disable Lint/RescueException
        destroy
        raise
      end

      def fiber(*, **, &work)
        check_owner
        raise IOError, "scheduler is closed" if @closed || @stopping
        raise FiberError, "scheduler must be installed" unless Fiber.scheduler.equal?(self)
        raise ArgumentError, "no block given" unless work
        admitting = true
        failure = nil
        task = Fiber.new(blocking: false) do
          work.call(*, **)
        rescue Exception => e # rubocop:disable Lint/RescueException
          raise unless admitting
          failure = e
        ensure
          @fibers.delete(Fiber.current)
          finish_fiber
        end
        @fibers[task] = true
        start_fiber(task)
        admitting = false
        raise failure if failure
        task
      rescue Exception # rubocop:disable Lint/RescueException
        shutdown if task && !@running && Fiber.current.equal?(@root)
        raise
      ensure
        admitting = false
      end

      def block(_blocker, timeout = nil)
        timeout = duration_value(timeout)
        token = arm_wait
        wait_with_timeout(token, timeout, false)
      ensure
        retire_wait(token) if token
      end

      def unblock(_blocker, fiber) # rubocop:disable Naming/PredicateMethod
        return false if @closed || !(token = current_wait(fiber))
        @mailbox << Completion.new(token, true, nil).freeze
        wakeup
        true
      end

      def fiber_interrupt(fiber, exception) # rubocop:disable Naming/PredicateMethod
        return false if @closed || !(token = current_wait(fiber))
        @mailbox << Completion.new(token, nil, exception).freeze
        wakeup
        true
      end

      def kernel_sleep(duration = nil)
        started = Clock.now
        block(nil, duration)
        Clock.now - started
      end

      def timeout_after(duration, klass = Timeout::Error, *)
        check_fiber
        duration = duration_value(duration)
        return yield(duration) unless duration
        timer = Timer.new(Clock.now + duration, nil, Fiber.current, klass.exception(*), true)
        @timers.push(timer.deadline, timer)
        policy_changed
        yield duration
      ensure
        remove_timer(timer) if timer
      end

      def yield
        token = arm_wait
        resume_wait(token, nil)
        suspend(token)
      end
      alias cooperate yield

      def address_resolve(hostname)
        check_fiber
        Resolv.getaddresses(hostname)
      end

      def process_wait(pid, flags)
        background { Process::Status.wait(pid, flags) }
      end

      def blocking_operation_wait(operation)
        # CRuby also invokes this hook from finalizers, where parking is illegal.
        # Keep the opaque runtime operation on its original stack. Explicit file
        # fallbacks use the thread pool. Process waits use separate threads.
        Fiber.blocking { operation.call }
      end

      def run
        check_root
        raise IOError, "scheduler is closed" if @closed || @stopping
        raise FiberError, "recursive scheduler run" if @running
        entered = @running = true
        until idle?
          service_policy
          break if idle?
          deadline = @timers.peek_priority
          timeout = deadline ? [deadline - Clock.now, 0].max : nil
          timeout = 0 if ready? || !@mailbox.empty?
          dispatch(timeout, @timers.empty? ? @dispatch_budget : 256)
        end
        true
      rescue Exception # rubocop:disable Lint/RescueException
        shutdown if entered
        raise
      ensure
        if entered
          @running = false
          finish_close if @closing
        end
      end

      def idle? = @fibers.empty? && !pending? && @timers.empty? && @mailbox.empty?
      def closed? = @closed

      # Return a lower bound for fibers that can resume immediately.
      def farce_runnable_count = scheduler_ready_count + @mailbox.size

      # Stop admission immediately. An active driver owns the drain and releases
      # resources after returning from dispatch. Destroying them here would leave
      # its native stack referring to freed state.
      def close # rubocop:disable Naming/PredicateMethod
        check_owner
        return true if @closed
        begin_close
        @closing = true
        return true if @running || !Fiber.current.equal?(@root)
        begin
          run unless @stopping
        ensure
          finish_close
        end
        true
      end

      # Ruby 3.4+ invokes this hook on scheduler replacement and thread exit.
      def scheduler_close(error = $!) # rubocop:disable Style/SpecialGlobalVars
        check_root
        raise FiberError, "recursive scheduler close" if @running
        return close unless error
        # The root is already unwinding: run task ensures without waiting for
        # ordinary completion, and preserve the exception that caused shutdown.
        begin_close
        @closing = true
        finish_close
        true
      end

      private

      def finish_close
        return if @closed
        shutdown
        destroy
        @timers.clear
        @mailbox.clear
        @closed = true
        @closing = false
      end

      def initialize_copy(*) = raise(TypeError, "fiber schedulers cannot be copied")
      def marshal_dump = raise(TypeError, "fiber schedulers cannot be marshalled")

      def check_owner
        raise ThreadError, "scheduler belongs to another thread" unless owner_thread.equal?(@owner)
      end

      def check_root
        check_owner
        raise FiberError, "operation requires the root fiber" unless Fiber.current.equal?(@root)
      end

      def check_fiber
        check_owner
        raise IOError, "scheduler is closed" if @closed || @stopping
        raise FiberError, "operation requires an admitted fiber" unless @fibers.key?(Fiber.current)
        raise FiberError, "scheduler must be installed" unless @closing || Fiber.scheduler.equal?(self)
      end

      def duration_value(value)
        return if value.nil?
        seconds = Float(value)
        raise ArgumentError, "invalid timeout" if seconds.nan? || seconds.negative?
        seconds.finite? ? seconds : nil
      end

      def suspend(token)
        @suspensions += 1
        park_current(token)
      end

      def wait_with_timeout(token, timeout, value)
        if timeout
          timer = Timer.new(Clock.now + timeout, token, nil, nil, true)
          @timers.push(timer.deadline, timer)
          policy_changed
        end
        result = suspend(token)
        result.nil? ? value : result
      ensure
        remove_timer(timer) if timer
      end

      def remove_timer(timer)
        timer.active = false
        @timers.delete_identity(timer.deadline, timer)
      end

      def with_io_timeout(duration, &)
        timeout_after(duration, IO::TimeoutError, "IO timed out", &)
      end

      def checkpoint_result(value)
        @immediate += 1
        if @immediate >= SLOT_COUNT
          @immediate = 0
          self.yield
        end
        value
      end

      def service_policy
        SLOT_COUNT.times do
          break if @mailbox.empty?
          item = @mailbox.pop(true)
          break unless item
          item.error ? interrupt_wait(item.token, item.error) : resume_wait(item.token, item.value)
        end
        return if @timers.empty?
        SLOT_COUNT.times do
          timer = @timers.pop_before(Clock.now)
          break unless timer
          next unless timer.active
          timer.active = false
          token = timer.token || current_wait(timer.fiber)
          next unless token
          timer.error ? interrupt_wait(token, timer.error) : resume_wait(token, nil)
        end
      end

      def background(&)
        check_fiber
        @thread_pool.call(&)
      end

      def shutdown
        begin_shutdown
        @stopping = true
        @fibers.keys.each do |task| # rubocop:disable Style/HashEachMethods
          next unless task.alive?
          begin
            task.raise(Cancelled.new("scheduler aborted"))
          rescue Exception # rubocop:disable Lint/RescueException
            # Preserve the initiating failure, while running other tasks' ensures.
          end
        end
      end
    end
  end
end
