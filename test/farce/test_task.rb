# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestTask < Test
    include Helpers::InternalTestHelpers

    class Payload
      include Unshareable::Copyable
      include Unshareable::Movable

      attr_accessor :value

      def initialize(value) = @value = value
    end

    class MutableError < StandardError
      def initialize
        @payload = Object.new
        super("task failed")
      end
    end

    def test_constructor_validation
      assert_raises(LocalJumpError) { Task.new }
      assert_raises(ArgumentError) { Task.new(mode: :invalid) { nil } }
      assert_equal :smart, Task.new { nil }.mode
    end

    def test_live_tasks_reject_marshaling
      %i[smart local].each do |mode|
        task = Task.new(mode:) { :done }

        assert_raises(TypeError) { Marshal.dump(task) }
        task.call

        assert_raises(TypeError) { Marshal.dump(task) }
      end
    end

    def test_manual_execution_and_value_interface
      task = Task.new(1) { |*args| args.sum }

      assert_kind_of Abstract::Value, task
      assert_predicate task, :alive?
      refute_predicate task, :frozen?
      refute_predicate task, :local?
      assert Ractor.shareable?(task)
      assert_same task, task.add_argument(2)
      assert_same task, task << 3
      assert_same task, task.call
      refute_predicate task, :alive?
      assert_predicate task, :frozen?
      assert_same task, task.join(0)
      assert_equal 6, task.value
      assert_equal 6, task.value(0)
      assert_equal 6, task.unwrap
      assert_raises(Task::InvalidStateError) { task.call }
      assert_raises(FrozenError) { task << 4 }
    end

    def test_local_tasks_preserve_arguments_callback_and_result
      argument = []
      result = Object.new
      receiver = self
      task = Task.new(argument, mode: :local) do |value|
        assert_same receiver, self
        assert_same argument, value
        value << :called
        result
      end

      assert_predicate task, :local?
      assert_same task, task.add_argument(:extra, mode: :ignored)
      assert_same task, task.call
      assert_same result, task.value
      assert_same result, task.value
      assert_equal [:called], argument
    end

    def test_freezing_seals_arguments_without_executing
      %i[smart local].each do |mode|
        task = Task.new(1, mode:) { |value| value }

        assert_same task, task.freeze
        assert_predicate task, :frozen?
        assert_predicate task, :alive?
        assert_raises(FrozenError) { task.add_argument(2) }
        assert_same task, task.call
        assert_equal 1, task.value
      end
    end

    def test_argument_mode_overrides_leave_result_mode_unchanged
      source = Payload.new(:original)
      task = Task.new(mode: :make_shareable) { |value| [value.value] }
      task.add_argument(source, mode: :copy)
      source.value = :changed
      task.call

      assert_equal [:original], task.value
      assert_predicate task.value, :frozen? if Internal.native_ractors?

      assert_equal :changed, source.value
      assert_equal :make_shareable, task.mode
      assert_raises(ArgumentError) { Task.new { nil }.add_argument(:value, mode: :invalid) }
    end

    def test_nonlocal_proc_is_shareable_and_executes_the_task
      task = Task.new(21) { |value| value * 2 }
      callback = task.to_proc

      assert_kind_of Proc, callback
      assert Ractor.shareable?(callback)
      assert_same task, Object.new.instance_exec(&callback)
      assert_equal 42, task.value
    end

    def test_local_proc_can_be_passed_to_a_thread
      task = Task.new(mode: :local) { :done }
      worker = Thread.new(&task)

      assert worker.join(5)
      assert_same task, worker.value
      assert_equal :done, task.value
    ensure
      worker&.kill&.join
    end

    def test_timeouts_before_execution_and_after_completion
      task = Task.new { false }

      assert_nil task.join(0)
      assert_nil task.value(0)
      assert_predicate task, :alive?
      [-1, Float::INFINITY, Float::NAN].each do |timeout|
        assert_raises(ArgumentError) { task.join(timeout) }
        assert_raises(ArgumentError) { task.value(timeout) }
      end
      task.call

      assert_same task, task.join(0)
      refute task.value(0)
    end

    def test_nil_result_still_completes
      task = Task.new { nil }
      task.call

      assert_same task, task.join(0)
      refute_predicate task, :alive?
      assert_nil task.value(0)
    end

    def test_running_task_rejects_arguments_and_a_second_call
      started = Thread::Queue.new
      release = Thread::Queue.new
      task = Task.new(mode: :local) do
        started << true
        release.pop
        :done
      end
      worker = Thread.new(&task)
      Timeout.timeout(5) { started.pop }

      assert_predicate task, :alive?
      assert_nil task.join(0)
      assert_nil task.value(0)
      assert_raises(FrozenError) { task << :late }
      assert_raises(Task::InvalidStateError) { task.call }
      release << true

      assert_same task, task.join(5)
      assert_equal :done, task.value
    ensure
      release&.close
      worker&.join(5) || worker&.kill&.join
    end

    def test_multiple_waiters_observe_the_same_completion
      started = Thread::Queue.new
      release = Thread::Queue.new
      task = Task.new(mode: :local) do
        release.pop
        :done
      end
      waiters = 4.times.map do
        Thread.new do
          started << true
          task.value(5)
        end
      end
      4.times { Timeout.timeout(5) { started.pop } }
      worker = Thread.new(&task)
      release << true

      waiters.each do |waiter|
        assert waiter.join(5)
        assert_equal :done, waiter.value
      end
    ensure
      release&.close
      worker&.join(5) || worker&.kill&.join
      waiters&.each { it.kill.join }
    end

    def test_local_failures_preserve_the_exception
      failure = MutableError.new
      task = Task.new(mode: :local) { raise failure }

      assert_same task, task.call
      refute_predicate task, :alive?
      assert_same task, task.join(0)
      2.times { assert_same failure, assert_raises(MutableError) { task.value } }
    end

    def test_unshareable_failures_have_a_readable_fallback
      task = Task.new { raise MutableError }

      assert_same task, task.call
      refute_predicate task, :alive?
      assert_same task, task.join(0)
      error = assert_raises(Internal.native_ractors? ? RuntimeError : MutableError) { task.value }
      assert_includes error.message, "MutableError: task failed" if Internal.native_ractors?

      assert_includes error.backtrace.first, "test_task.rb"
    end

    def test_result_transfer_failure_finishes_the_task
      return unless Internal.native_ractors?
      task = Task.new(mode: :raise) { Object.new }

      assert_same task, task.call
      refute_predicate task, :alive?
      assert_same task, task.join(0)
      assert_raises(StandardError) { task.value }
    end

    def test_failures_outside_standard_error_finish_the_task
      task = Task.new(mode: :local) { raise NotImplementedError, "unavailable" }

      assert_same task, task.call
      refute_predicate task, :alive?
      assert_same task, task.join(0)
      error = assert_raises(NotImplementedError) { task.value }
      assert_equal "unavailable", error.message
    end

    def test_only_one_concurrent_caller_executes_the_callback
      counter = Counter.new
      task = Task.new(counter, &:increment)
      callers = 8.times.map do
        Thread.new do
          task.call
        rescue Task::InvalidStateError
          :rejected
        end
      end
      callers.each { assert it.join(5) }

      assert_equal 1, counter.value
      assert_equal(1, callers.count { it.value.equal?(task) })
      assert_equal(7, callers.count { it.value == :rejected })
      assert_equal 1, task.value
    ensure
      callers&.each { it.kill.join }
    end

    def test_a_remote_ractor_can_execute_and_publish_a_result
      task = Task.new(Payload.new(:input), mode: :copy) { |value| Payload.new(value.value) }
      worker = Ractor.new(task) do |job|
        job.call
        :done
      end

      assert_equal :done, ractor_value(worker)
      assert_same task, task.join(5)
      assert_equal :input, task.value.value
      assert_same task.value, task.value
      assert_raises(Task::InvalidStateError) { task.call }
    end

    def test_local_argument_claims_a_nonlocal_task_for_its_origin
      value = Object.new
      task = Task.new { |argument| argument.class.name }
      task.add_argument(value, mode: :local)
      worker = Ractor.new(task) do |job|
        job.call
      rescue Task::InvalidStateError
        :rejected
      end

      assert_equal :rejected, ractor_value(worker)
      assert_predicate task, :alive?
      task.call

      assert_equal "Object", task.value
    end

    def test_a_local_argument_cannot_be_added_by_another_ractor
      task = Task.new { nil }
      task.add_argument(Object.new, mode: :local)
      worker = Ractor.new(task) do |job|
        job.add_argument(Object.new, mode: :local)
      rescue Task::InvalidStateError
        :rejected
      end

      assert_equal :rejected, ractor_value(worker)
    end

    def test_argument_transfer_failure_finishes_the_task
      task = Task.new(Payload.new(:input), mode: :move, &:value)
      envelope = task.instance_variable_get(:@arguments)[0]
      worker = Ractor.new(envelope) do |value|
        value.value
        :claimed
      end

      assert_equal :claimed, ractor_value(worker)

      assert_same task, task.call
      refute_predicate task, :alive?
      assert_same task, task.join(0)
      assert_raises(StandardError) { task.value(0) }
    end

    def test_schedule_uses_an_explicit_local_executor
      executor = ThreadExecutor.new
      argument = []
      task = Task.schedule(argument, scheduler: executor) { |value| value << :done }

      assert_instance_of Task, task
      assert_predicate task, :local?
      assert_same task, task.join(5)
      assert_same argument, task.value
      assert_equal [:done], argument
    end

    def test_auto_local_can_be_disabled
      task = Task.schedule(21, scheduler: ThreadExecutor.new, auto_local: false) { |value| value * 2 }

      assert_equal :smart, task.mode
      assert_equal 42, task.value(5)
    end

    def test_try_schedule_returns_nil_when_the_executor_queue_is_full
      scheduler = Unshared::Scheduler.new(capacity: 1)
      task = Task.try_schedule(:first, scheduler:) { |value| value }

      assert_instance_of Task, task
      assert_nil(Task.try_schedule(scheduler:) { flunk "rejected task ran" })
      worker = scheduler.launch_thread

      assert_same task, task.join(5)
      assert_equal :first, task.value
      second = Task.try_schedule(:second, scheduler:) { |value| value }

      assert_equal :second, second.value(5)
    ensure
      scheduler&.close
      worker&.join(5) || worker&.kill&.join
    end

    def test_closed_executors_reject_submission
      scheduler = Unshared::Scheduler.new
      scheduler.close

      assert_raises(SchedulerClosedError) { Task.schedule(scheduler:) { nil } }
      assert_raises(SchedulerClosedError) { Task.try_schedule(scheduler:) { nil } }
    end

    def test_scheduling_requires_a_callback
      %i[schedule try_schedule in_parallel on_main].each do |method|
        assert_raises(LocalJumpError) { Task.public_send(method) }
      end
    end

    def test_on_main_schedules_on_the_main_ractor
      task = Task.on_main(21) { |value| [value * 2, Ractor.current] }

      assert_instance_of Task, task
      assert_predicate task, :local?
      assert_equal [42, Ractor.main], task.value(5)
    end

    def test_in_parallel_transfers_arguments_and_result
      task = Task.in_parallel(21) { |value| value * 2 }

      assert_instance_of Task, task
      assert_equal :smart, task.mode
      assert_equal 42, task.value(5)
    end

    def test_default_scheduling_and_remote_parallel_fallback
      task = Task.schedule(21) { |value| value * 2 }

      assert_predicate task, :local?
      assert_equal 42, task.value(5)
      worker = Ractor.new do
        Task.schedule(21) { |value| value * 2 }.value(5)
      end

      assert_equal 42, ractor_value(worker)
    end

    def test_scheduling_on_an_explicit_fiber_scheduler
      return unless Fiber.respond_to?(:set_scheduler)
      return if RUBY_ENGINE == "truffleruby"
      scheduler = Unshared::Scheduler.new
      argument = []
      Fiber.set_scheduler(scheduler)
      task = Task.schedule(argument, scheduler: Fiber.scheduler) { |value| value << :done }
      scheduler.close
      Fiber.set_scheduler(nil)

      assert_predicate task, :local?
      assert_same argument, task.value(0)
      assert_equal [:done], argument
    ensure
      scheduler&.close
      Fiber.set_scheduler(nil) if Fiber.respond_to?(:set_scheduler)
    end

    def test_all_modes_accept_shareable_arguments_and_results
      Farce::MODES.each do |mode|
        task = Task.new(21, mode:) { |value| value * 2 }
        task.call

        assert_equal mode, task.mode
        assert_equal 42, task.value
      end
    end

    def test_snapshot_modes_transfer_nonshareable_arguments_and_results
      %i[copy marshal].each do |mode|
        argument = Payload.new(:input)
        task = Task.new(argument, mode:) { |value| Payload.new(value.value) }
        argument.value = :changed
        task.call

        assert_equal :input, task.value.value
        refute_same argument, task.value
        assert_same task.value, task.value
      end
    end

    def test_move_result_belongs_to_the_first_reader
      task = Task.new(mode: :move) { Payload.new(:result) }
      worker = Ractor.new(task) do |job|
        job.call
        :done
      end

      assert_equal :done, ractor_value(worker)
      assert_equal :result, task.value.value
      assert_same task.value, task.value
      reader = Ractor.new(task) do |job|
        job.value
      rescue Ractor::Error
        :rejected
      end

      assert_equal :rejected, ractor_value(reader)
    end

    def test_nonlocal_failures_can_be_read_from_another_ractor
      task = Task.new do
        raise ArgumentError, "task failed"
      end
      worker = Ractor.new(task) do |job|
        job.call
        :done
      end

      assert_equal :done, ractor_value(worker)
      assert_same task, task.join(5)
      reader = Ractor.new(task) do |job|
        job.value
      rescue StandardError => e
        [e.class.name, e.message, e.backtrace.first.include?("test_task.rb")]
      end
      failure = ractor_value(reader)

      assert_equal Internal.native_ractors? ? "RuntimeError" : "ArgumentError", failure[0]
      assert_includes failure[1], "task failed"
      assert failure[2]
    end

    def test_on_main_can_be_submitted_from_another_ractor
      worker = Ractor.new do
        Task.on_main { Ractor.current }.value(5)
      end

      assert_same Ractor.main, ractor_value(worker)
    end

    def test_local_scheduling_creates_a_scheduler_in_another_ractor
      output, error, status = ruby_isolated(<<~RUBY)
        require "farce"
        worker = Farce::Ractor.new do
          task = Farce::Task.schedule(mode: :local) { :done }
          abort "wrong mode" unless task.local?
          abort "wrong result" unless task.value(5) == :done
          Farce.const_get(:Internal).local_scheduler.close
          :done
        end
        result = worker.respond_to?(:value) ? worker.value : worker.take
        abort "worker failed" unless result == :done
        puts "done"
      RUBY

      assert_predicate status, :success?, error
      assert_equal "done\n", output
    end

    def test_task_waiting_yields_to_other_scheduler_fibers
      return unless Fiber.respond_to?(:set_scheduler)
      return if RUBY_ENGINE == "truffleruby"
      output, error, status = ruby_subprocess(<<~RUBY)
        require "farce"
        scheduler = Farce::Unshared::Scheduler.new
        Fiber.set_scheduler(scheduler)
        result = []
        task = Farce::Task.new(mode: :local) { :done }
        Fiber.schedule { result << task.value(5) }
        Fiber.schedule { task.call }
        scheduler.close
        Fiber.set_scheduler(nil)
        abort "waiter blocked execution: \#{result.inspect}" unless result == [:done]
        puts "done"
      RUBY

      assert_predicate status, :success?, error
      assert_equal "done\n", output
    end

    def test_tasks_can_be_queued_before_a_scheduler_is_launched
      scheduler = Scheduler.new(capacity: 1)
      task = Timeout.timeout(5) { Task.try_schedule(21, scheduler:) { |value| value * 2 } }

      assert_instance_of Task, task
      assert_nil(Timeout.timeout(5) { Task.try_schedule(scheduler:) { nil } })
      worker = scheduler.launch_thread

      assert_equal 42, task.value(5)
    ensure
      scheduler&.close
      worker&.join(5) || worker&.kill&.join
    end

    def test_killing_the_worker_finishes_the_task
      started = Thread::Queue.new
      release = Thread::Queue.new
      task = Task.new(mode: :local) do
        started << true
        release.pop
      end
      worker = Thread.new(&task)
      Timeout.timeout(5) { started.pop }
      worker.kill

      assert worker.join(5)
      refute_predicate task, :alive?
      assert_same task, task.join(0)
      error = assert_raises(RuntimeError) { task.value(0) }
      assert_equal "task execution aborted", error.message
    ensure
      release&.close
      worker&.kill&.join
    end

    def test_throwing_out_of_the_callback_finishes_the_task
      task = Task.new(mode: :local) { throw :task_exit }

      assert_nil(catch(:task_exit) { task.call })
      refute_predicate task, :alive?
      assert_same task, task.join(0)
      assert_raises(RuntimeError) { task.value(0) }
    end
  end
end
