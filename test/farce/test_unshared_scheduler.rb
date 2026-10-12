# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "test_scheduler"

module Farce
  class TestUnsharedScheduler < Test
    include Helpers::InternalTestHelpers
    include TestScheduler::Contract

    def test_initialization
      scheduler = scheduler_class.new

      assert_equal :initialized, scheduler.state
      assert_same Ractor.current, scheduler.owner
      assert_predicate scheduler, :local?
      assert scheduler.local?(wait: false)
      assert_nil scheduler.error
      assert_nil scheduler.external_scheduler
      refute_predicate scheduler, :alive?
      refute_predicate scheduler, :closed?
      refute_predicate scheduler, :wraps_external?
      refute_predicate scheduler, :ractor_shareable?
      refute Ractor.shareable?(scheduler) if Internal.native_ractors?

      assert_instance_of Internal::UnsharedQueue, backend_scheduler(scheduler).instance_variable_get(:@queue)
    end

    def test_schedule_retains_arguments_and_binding_in_the_creating_ractor
      scheduler = scheduler_class.new
      results = Unshared::Queue.new
      values = Unshared::Map.new
      caller_self = self
      caller_ractor = Ractor.current
      caller_thread = Thread.current
      worker = scheduler.launch_thread
      scheduler.schedule(values) { |value| results << [value, self, Ractor.current, Thread.current] }
      value, receiver, ractor, thread = results.pop(timeout: 5)

      assert_same values, value
      assert_same caller_self, receiver
      assert_same caller_ractor, ractor
      refute_same caller_thread, thread
    ensure
      scheduler&.close
      worker&.join(5) || worker&.kill&.join
    end

    def test_tasks_can_be_enqueued_before_launch
      scheduler = scheduler_class.new
      results = Unshared::Queue.new
      values = [:original]

      assert_same scheduler, scheduler.schedule(values) { |value| results << value }
      values << :changed
      worker = scheduler.launch_thread

      assert_same values, results.pop(timeout: 5)
      assert_equal %i[original changed], values
    ensure
      scheduler&.close
      worker&.join(5) || worker&.kill&.join
    end

    def test_automatic_local_transfer_overrides_the_mode
      scheduler = scheduler_class.new
      queue = backend_scheduler(scheduler).instance_variable_get(:@queue)
      values = Unshared::Map.new
      %i[schedule try_schedule].each do |submission|
        [*Farce::MODES, :unknown, nil].each do |mode|
          returned = scheduler.public_send(submission, values, mode:) { |value| [value, self] }
          value, receiver = queue.pop.to_proc.call

          assert_same scheduler, returned
          assert_same values, value
          assert_same self, receiver
          assert_same(scheduler, scheduler.execute(values, mode:) { |value| assert_same values, value })
        end
      end

      refute_predicate values, :frozen?
    end

    def test_disabled_auto_local_accepts_only_local_and_smart_modes
      scheduler = scheduler_class.new
      queue = backend_scheduler(scheduler).instance_variable_get(:@queue)
      values = Unshared::Map.new
      accepted = %i[local smart smart_raise smart_move smart_copy]
      accepted.each do |mode|
        %i[schedule try_schedule].each do |submission|
          scheduler.public_send(submission, values, mode:, auto_local: false) { |value| [value, self] }
          value, receiver = queue.pop.to_proc.call

          assert_same values, value
          assert_same self, receiver
        end
        assert_same(scheduler, scheduler.execute(values, mode:, auto_local: false) do |value|
          assert_same values, value
        end)
      end
      (Farce::MODES.to_a - accepted + [:unknown, nil]).each do |mode|
        %i[schedule try_schedule].each do |submission|
          assert_raises(ArgumentError) { scheduler.public_send(submission, values, mode:, auto_local: false) { nil } }
        end
        assert_raises(ArgumentError) { scheduler.execute(values, mode:, auto_local: false) { nil } }
      end

      assert_equal 0, queue.size
      refute_predicate values, :frozen?
    end

    def test_execute_preserves_arguments_binding_thread_and_fiber
      scheduler = scheduler_class.new
      values = []
      caller_self = self
      caller_thread = Thread.current
      caller_fiber = Fiber.current
      [true, false].each do |auto_local|
        returned = scheduler.execute(values, :done, auto_local:) do |array, value|
          assert_same values, array
          assert_same caller_self, self
          assert_same caller_thread, Thread.current
          assert_same caller_fiber, Fiber.current
          array << value
        end

        assert_same scheduler, returned
      end

      assert_equal %i[done done], values
      assert_equal 0, backend_scheduler(scheduler).instance_variable_get(:@queue).size
    end

    def test_execute_propagates_local_exceptions
      scheduler = scheduler_class.new
      failure = ArgumentError.new("task failed")

      assert_same failure, assert_raises(ArgumentError) { scheduler.execute { raise failure } }
    end

    def test_close_rejects_execution
      scheduler = scheduler_class.new
      scheduler.close

      assert_raises(SchedulerClosedError) { scheduler.execute { flunk "executed after close" } }
    end

    def test_missing_block_is_rejected
      scheduler = scheduler_class.new

      assert_raises(LocalJumpError) { scheduler.schedule }
      assert_raises(LocalJumpError) { scheduler.execute }
      assert_equal 0, backend_scheduler(scheduler).instance_variable_get(:@queue).size
    end

    def test_constructor_respects_ractor_boundary
      return unless Fiber.respond_to?(:set_scheduler)
      constructors = Unshared::Queue.new
      results = Unshared::Queue.new
      scheduler = scheduler_class.new do
        external = Helpers::Internal::FiberScheduler.new
        constructors << [external, Ractor.current, Thread.current]
        external
      end

      assert_equal 0, constructors.size
      worker = scheduler.launch_thread
      external, ractor, thread = constructors.pop(timeout: 5)
      scheduler.schedule { results << Fiber.scheduler }

      assert_same external, results.pop(timeout: 5)
      assert_same external, scheduler.external_scheduler
      assert_same Ractor.current, ractor
      refute_same Thread.current, thread
    ensure
      scheduler&.close
      worker&.join(5) || worker&.kill&.join
    end

    def test_create_defaults_to_a_thread_in_the_creating_ractor
      results = Unshared::Queue.new
      scheduler = scheduler_class.create
      scheduler.schedule { results << Ractor.current }

      assert_same Ractor.current, results.pop(timeout: 5)
      assert_equal :running, scheduler.state
      scheduler.close
      deadline = Clock.now + 5
      sleep 0.001 until scheduler.state == :closed || Clock.now >= deadline

      assert_equal :closed, scheduler.state
    ensure
      scheduler&.close
    end

    def test_launch_defaults_to_thread_including_explicit_nil
      [:default, nil].each do |executor|
        scheduler = scheduler_class.new
        worker = executor == :default ? scheduler.launch : scheduler.launch(executor)

        assert_instance_of Thread, worker
        assert_same Ractor.current, scheduler.owner
        scheduler.close

        assert worker.join(5), "scheduler worker did not stop"
      ensure
        scheduler&.close
        worker&.kill&.join
      end
    end

    def test_ractor_launch_is_rejected_before_startup
      scheduler = scheduler_class.new

      assert_raises(ArgumentError) { scheduler.launch_ractor }
      assert_raises(ArgumentError) { scheduler.launch(Ractor) }
      assert_raises(ArgumentError) { scheduler_class.create(Ractor) }
      assert_equal :initialized, scheduler.state
      assert_nil scheduler.error
      worker = scheduler.launch_thread

      assert_instance_of Thread, worker
      assert_equal :running, scheduler.state
    ensure
      scheduler&.close
      worker&.join(5) || worker&.kill&.join
    end

    def test_owner_cannot_be_reassigned
      scheduler = scheduler_class.new
      other = Ractor.new { Ractor.current }

      assert_raises(ArgumentError) { scheduler.owner = Object.new }
      assert_raises(ArgumentError) { scheduler.owner = ractor_value(other) }
      assert_raises(ArgumentError) { scheduler.owner = nil }
      assert_same Ractor.current, scheduler.owner
    end

    def test_scheduler_cannot_be_copied_or_marshaled
      scheduler = scheduler_class.new

      assert_raises(TypeError) { scheduler.dup }
      assert_raises(TypeError) { scheduler.clone }
      assert_raises(TypeError) { Marshal.dump(scheduler) }
    end

    def test_ractor_transfer_contract
      return unless Internal.native_ractors?
      scheduler = scheduler_class.new

      assert_raises(Ractor::Error) { Ractor.make_shareable(scheduler) }
      assert_raises(TypeError, Ractor::Error) { Ractor.new(scheduler) { nil } }
      receiver = Ractor.new { Ractor.receive }
      assert_raises(TypeError, Ractor::Error) { receiver.send(scheduler, move: true) }
      receiver.send(:done)

      assert_equal :done, ractor_value(receiver)
    end

    def test_workers_created_in_a_secondary_ractor_remain_local
      results = Queue.new
      caller = Ractor.new(results) do |output|
        scheduler = Unshared::Scheduler.new
        local_values = []
        worker = scheduler.launch_thread
        scheduler.schedule(local_values) do |values|
          values << :done
          output << [Ractor.current, values.equal?(local_values), values[0]].freeze
        end
        scheduler.close
        worker.join
        scheduler.state
      end
      ractor, same_argument, value = results.pop(timeout: 5)

      assert_same caller, ractor
      assert same_argument
      assert_equal :done, value
      assert_equal :closed, ractor_value(caller)
    end

    private

    def scheduler_class = Unshared::Scheduler
  end
end
