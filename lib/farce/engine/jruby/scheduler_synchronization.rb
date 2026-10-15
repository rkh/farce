# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal # :nodoc: all
    # JRuby can release a mutex and notify its waiter before block is entered.
    module SchedulerSynchronization
      class WaitMutex < ::Mutex
        def synchronize
          # Registering a wait must never recursively invoke this scheduler.
          Fiber.blocking { super }
        end
      end
      MutexWait = Struct.new(:blocker, :notification)
      private_constant :WaitMutex, :MutexWait

      def initialize(...)
        super
        @wait_mutex    = WaitMutex.new
        @mutex_wakeups = {}.compare_by_identity
      end

      def block(blocker, timeout = nil)
        return super unless blocker.is_a?(::Mutex)
        timeout = duration_value(timeout)
        check_fiber
        waiting = @wait_mutex.synchronize do
          @mutex_wakeups.fetch(Fiber.current).tap { it.blocker = blocker }
        end
        token = arm_wait
        early = @wait_mutex.synchronize do
          waiting.notification.tap { waiting.notification = nil }
        end
        resume_wait(token, true) if early.equal?(blocker)
        wait_with_timeout(token, timeout, false)
      ensure
        retire_wait(token) if token
        @wait_mutex.synchronize { waiting.blocker = waiting.notification = nil } if waiting
      end

      def unblock(blocker, fiber)
        return super unless blocker.is_a?(::Mutex)
        @wait_mutex.synchronize do
          return false if @closed || @stopping || !(waiting = @mutex_wakeups[fiber])
          token = @waiting[fiber]
          if token
            return false unless waiting.blocker.equal?(blocker)
            complete_wait(token, true)
            return true
          end

          # Keep one early notification per admitted fiber. Matching the blocker
          # prevents it from waking a different wait, and retirement consumes it.
          waiting.notification = blocker
          true
        end
      end

      private

      def start_fiber(fiber)
        @wait_mutex.synchronize { @mutex_wakeups[fiber] = MutexWait.new }
        super
      end

      def finish_fiber
        @wait_mutex.synchronize { @mutex_wakeups.delete(Fiber.current) }
        super
      end

      def retire_wait(token)
        @wait_mutex.synchronize do
          wait = @waits[token]
          waiting = @mutex_wakeups[wait.fiber] if wait
          waiting.blocker = waiting.notification = nil if waiting
        end
        super
      end

      def destroy
        @wait_mutex&.synchronize { @mutex_wakeups&.clear }
        super
      end
    end
  end
end
