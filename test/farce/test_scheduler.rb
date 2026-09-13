# frozen_string_literal: true

require_relative "../setup"

module Farce
  class TestScheduler < Test
    include Helpers::InternalTestHelpers

    class InlineExecutor
      def self.new(*, &block)
        allocate.tap { block.call(*) }
      end
    end

    def test_initialization
      scheduler = Scheduler.new

      assert_equal :initialized, scheduler.state
      assert_nil scheduler.owner
      assert_nil scheduler.error
      assert_nil scheduler.external_scheduler
      refute_predicate scheduler, :alive?
      refute_predicate scheduler, :closed?
      refute_predicate scheduler, :wraps_external?
      assert_predicate scheduler, :frozen?
      assert_predicate scheduler, :ractor_shareable?
      assert Ractor.shareable?(scheduler)
    end

    def test_capacity_is_normalized_and_forwarded_to_the_queue
      scheduler = Scheduler.new(capacity: "2")
      queue = scheduler.instance_variable_get(:@queue)

      assert_equal 2, queue.capacity
      assert_nil Scheduler.new(capacity: nil).instance_variable_get(:@queue).capacity
      assert_raises(TypeError) { Scheduler.new(capacity: Object.new) }
    end

    def test_external_scheduler_constructor_is_deferred
      scheduler = Scheduler.new { raise "constructor should not run during initialization" }

      assert_predicate scheduler, :wraps_external?
      assert_nil scheduler.external_scheduler
      assert_equal :initialized, scheduler.state
    end

    def test_external_scheduler_rejects_access_from_another_ractor
      scheduler = Scheduler.new { raise "constructor should not run" }
      other = Ractor.new { Ractor.current }
      scheduler.owner = ractor_value(other)

      assert_raises(Ractor::IsolationError) { scheduler.external_scheduler }
    end

    def test_owner_can_be_assigned_idempotently
      scheduler = Scheduler.new

      assert_same Ractor.current, scheduler.owner = Ractor.current
      assert_same Ractor.current, scheduler.owner = Ractor.current
      assert_same Ractor.current, scheduler.owner
    end

    def test_owner_rejects_invalid_values_and_reassignment
      scheduler = Scheduler.new

      error = assert_raises(ArgumentError) { scheduler.owner = Object.new }
      assert_equal "owner must be a Ractor", error.message

      scheduler.owner = Ractor.current
      other = Ractor.new { Ractor.current }

      error = assert_raises(ArgumentError) { scheduler.owner = ractor_value(other) }
      assert_equal "owner has already been set", error.message
    end

    def test_close_is_idempotent_and_rejects_new_tasks
      scheduler = Scheduler.new

      assert_same scheduler, scheduler.close
      assert_same scheduler, scheduler.close
      assert_equal :closing, scheduler.state
      assert_predicate scheduler, :closed?
      refute_predicate scheduler, :alive?
      assert_same Ractor.current, scheduler.owner

      error = assert_raises(SchedulerClosedError) { scheduler.schedule { nil } }
      assert_equal "cannot schedule task on a closed scheduler", error.message
    end

    def test_close_rejects_a_submission_waiting_for_ownership
      scheduler = Scheduler.new
      result = Thread::Queue.new
      submitter = Thread.new do
        scheduler.schedule { nil }
        result << :scheduled
      rescue Exception => e # rubocop:disable Lint/RescueException
        result << e
      end

      Timeout.timeout(2) { Thread.pass until submitter.status == "sleep" }
      scheduler.close

      assert submitter.join(2), "submission remained blocked after close"
      assert_instance_of SchedulerClosedError, result.pop
    ensure
      submitter&.kill&.join
    end

    def test_schedule_preserves_local_arguments_and_block
      queue = Internal::Queue.new
      scheduler = Scheduler.new(queue:)
      scheduler.owner = Ractor.current
      result = []

      assert_same scheduler, scheduler.schedule(result, :value) { |array, value| array << value }

      task = queue.pop

      assert_instance_of Envelope::Local, task
      task.value.call

      assert_equal [:value], result
    end

    def test_schedule_copies_remote_arguments
      return unless Internal.native_ractors?
      queue = Internal::Queue.new
      scheduler = Scheduler.new(queue:)
      source = [:original]

      scheduler.schedule(source, auto_local: false) { it[0] }
      source[0] = :changed

      assert_equal :original, queue.pop.to_proc.call
    end

    def test_schedule_honors_raise_mode
      return unless Internal.native_ractors?
      queue = Internal::Queue.new
      scheduler = Scheduler.new(queue:)

      error = assert_raises(Ractor::IsolationError) do
        scheduler.schedule(Object.new, mode: :raise, auto_local: false) { nil }
      end

      assert_match(/value is not Ractor-shareable/, error.message)
      assert_equal 0, queue.size
    end

    def test_installing_as_fiber_scheduler_dispatches_tasks
      return if RUBY_ENGINE == "truffleruby"
      return unless Fiber.respond_to?(:set_scheduler)
      scheduler = Scheduler.new
      result = []

      Fiber.set_scheduler(scheduler)

      assert_equal :running, scheduler.state
      assert_predicate scheduler, :alive?
      refute_same scheduler, Fiber.scheduler

      scheduler.schedule(result, scheduler) do |values, handle|
        values << :task
        handle.close
      end
      Fiber.set_scheduler(nil)

      assert_equal [:task], result
      assert_equal :closed, scheduler.state
      assert_predicate scheduler, :closed?
      assert_nil Fiber.scheduler
    ensure
      close_installed_scheduler(scheduler)
    end

    def test_current_returns_nil_without_an_installed_fiber_scheduler
      return if RUBY_ENGINE == "truffleruby"
      return unless Fiber.respond_to?(:scheduler)

      assert_nil Fiber.scheduler
      assert_nil Scheduler.current
    end

    def test_current_returns_a_directly_installed_farce_scheduler
      return if RUBY_ENGINE == "truffleruby"
      return unless Fiber.respond_to?(:set_scheduler)
      scheduler = Scheduler.new

      Fiber.set_scheduler(scheduler)

      assert_same scheduler, Scheduler.current
      assert_same scheduler, Scheduler.current
    ensure
      close_installed_scheduler(scheduler)
    end

    def test_current_wraps_an_existing_fiber_scheduler_once
      return if RUBY_ENGINE == "truffleruby"
      return unless Fiber.respond_to?(:set_scheduler)
      external = Helpers::QueueTestScheduler.new
      wrapper = nil

      Fiber.set_scheduler(external)
      wrapper = Scheduler.current(capacity: nil)

      assert_instance_of Scheduler, wrapper
      assert_same wrapper, Scheduler.current
      assert_predicate wrapper, :wraps_external?
      assert_same external, wrapper.external_scheduler
      assert_same external, Fiber.scheduler
    ensure
      close_installed_scheduler(wrapper)
      Fiber.set_scheduler(nil) if Fiber.respond_to?(:scheduler) && Fiber.scheduler
    end

    def test_installed_scheduler_exposes_task_failure
      return if RUBY_ENGINE == "truffleruby"
      return unless Fiber.respond_to?(:set_scheduler)
      scheduler = Scheduler.new
      Fiber.set_scheduler(scheduler)
      scheduler.schedule { raise ArgumentError, "task failed" }

      error = assert_raises(ArgumentError) { Fiber.set_scheduler(nil) }

      assert_equal "task failed", error.message
      assert_equal :error, scheduler.state
      assert_predicate scheduler, :closed?
      assert_instance_of ArgumentError, scheduler.error
      assert_equal "task failed", scheduler.error.message
    ensure
      Fiber.set_scheduler(nil) if Fiber.respond_to?(:scheduler) && Fiber.scheduler
    end

    def test_launch_thread_dispatches_tasks_and_applies_worker_options
      scheduler = Scheduler.new
      result = Thread::Queue.new
      worker = Timeout.timeout(2) { scheduler.launch_thread(name: "farce-test", priority: 1) }

      assert_instance_of Thread, worker
      assert_equal :running, scheduler.state
      assert_same Ractor.current, scheduler.owner
      assert_equal "farce-test", worker.name
      assert_equal 1, worker.priority

      scheduler.schedule(result, scheduler) do |queue, handle|
        queue << :done
        handle.close
      end

      assert worker.join(5), "scheduler worker did not stop"
      assert_equal :done, result.pop
      assert_equal :closed, scheduler.state
      assert_nil scheduler.error

      error = assert_raises(RuntimeError) { scheduler.launch_thread }
      assert_equal "Scheduler may not be reused", error.message
    ensure
      worker&.kill&.join
    end

    def test_launch_thread_resumes_tasks_while_waiting_for_submissions
      scheduler = Scheduler.new
      result = Thread::Queue.new
      worker = scheduler.launch_thread

      scheduler.schedule(result) do |queue|
        sleep 0.01
        queue << :done
      end

      assert_equal :done, result.pop(timeout: 2)
      scheduler.close

      assert worker.join(5), "scheduler worker did not stop after close"
    ensure
      scheduler&.close
      worker&.join(5)
    end

    def test_launch_records_and_reraises_setup_failure
      return unless Fiber.respond_to?(:set_scheduler)
      scheduler = Scheduler.new { raise ArgumentError, "setup failed" }

      error = assert_raises(ArgumentError) { scheduler.launch(InlineExecutor) }

      assert_equal "setup failed", error.message
      assert_equal :error, scheduler.state
      assert_predicate scheduler, :closed?
      assert_instance_of ArgumentError, scheduler.error
      assert_equal "setup failed", scheduler.error.message
    end

    def test_create_returns_a_running_scheduler
      result = Thread::Queue.new
      worker = nil
      executor = Class.new
      # Capture the worker at launch. JRuby fibers can expose a different Thread.current.
      executor.define_singleton_method(:new) do |*args, &block|
        worker = Thread.new(*args, &block)
      end
      scheduler = Timeout.timeout(2) { Scheduler.create(executor, capacity: nil) }

      assert_instance_of Scheduler, scheduler
      assert_equal :running, scheduler.state

      scheduler.schedule(result, scheduler) do |queue, handle|
        queue << :done
        handle.close
      end

      assert worker.join(5), "created scheduler worker did not stop"
      assert_equal :done, result.pop(true)

      assert_equal :closed, scheduler.state
    ensure
      worker&.kill&.join(5)
    end

    private

    def close_installed_scheduler(scheduler)
      return unless Fiber.respond_to?(:scheduler) && Fiber.scheduler
      scheduler.schedule(scheduler, &:close) if scheduler && !scheduler.closed?
      Fiber.set_scheduler(nil)
    rescue SchedulerClosedError
      Fiber.set_scheduler(nil) if Fiber.scheduler
    end
  end
end
