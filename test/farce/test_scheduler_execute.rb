# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestSchedulerExecute < Test
    include Helpers::InternalTestHelpers

    def setup
      @queue = Internal::Queue.new
      @scheduler = Scheduler.new(queue: @queue)
      @scheduler.owner = Ractor.current
    end

    def test_local_execution_preserves_arguments_binding_and_fiber
      values = []
      caller_fiber = Fiber.current
      caller_self = self

      result = @scheduler.execute(values, :done) do |array, value|
        assert_same values, array
        assert_same caller_self, self
        assert_same caller_fiber, Fiber.current
        array << value
        :ignored
      end

      assert_same @scheduler, result
      assert_equal [:done], values
      assert_equal 0, @queue.size
    end

    def test_local_execution_without_arguments
      called = false

      assert_same(@scheduler, @scheduler.execute { called = true })
      assert called
    end

    def test_explicit_local_execution
      called = false
      @scheduler.execute(mode: :local, auto_local: false) { called = true }

      assert called
      assert_equal 0, @queue.size
    end

    def test_explicit_local_scheduling_accepts_the_owner
      values = []
      @scheduler.schedule(mode: :local, auto_local: false) { values << :done }
      @queue.pop.value.call

      assert_equal [:done], values
    end

    def test_explicit_local_execution_rejects_another_owner
      other = Ractor.new { Ractor.current }
      @scheduler = Scheduler.new(queue: @queue)
      @scheduler.owner = ractor_value(other)

      assert_raises(Ractor::IsolationError) { @scheduler.execute(mode: :local, auto_local: false) { nil } }
      assert_equal 0, @queue.size
    end

    def test_local_execution_propagates_exceptions
      failure = ArgumentError.new("task failed")

      assert_same failure, assert_raises(ArgumentError) { @scheduler.execute { raise failure } }
    end

    def test_closed_scheduler_rejects_execution
      @scheduler.close
      assert_raises(SchedulerClosedError) { @scheduler.execute { flunk "executed after close" } }
    end

    def test_missing_block_is_rejected_before_submission
      assert_raises(LocalJumpError) { Timeout.timeout(2) { @scheduler.execute(auto_local: false) } }
      assert_equal 0, @queue.size
    end

    def test_queued_execution_waits_for_completion_and_copies_arguments
      source = [:original]
      result = Queue.new
      started = Queue.new
      release = Queue.new
      submitter = Thread.new do
        @scheduler.execute(source, result, started, release, auto_local: false) do |data, output, ready, gate|
          ready << :started
          gate.pop
          output << data[0]
        end
      end
      task = Timeout.timeout(2) { @queue.pop }
      source[0] = :changed
      worker = Thread.new { task.to_proc.call }

      assert_equal :started, Timeout.timeout(2) { started.pop }
      assert_predicate submitter, :alive?
      release << :continue

      assert submitter.join(2), "execute did not return after completion"
      assert_same @scheduler, submitter.value
      assert_equal Internal.native_ractors? ? :original : :changed, result.pop
      assert worker.join(2)
    ensure
      submitter&.kill&.join
      worker&.kill&.join
    end

    def test_queued_failure_releases_the_caller
      submitter = Thread.new do
        @scheduler.execute(auto_local: false) { raise ArgumentError, "task failed" }
      end
      task = Timeout.timeout(2) { @queue.pop }
      error = assert_raises(ArgumentError) { task.to_proc.call }
      assert_equal "task failed", error.message
      assert submitter.join(2), "execute remained blocked after task failure"
      assert_same @scheduler, submitter.value
    ensure
      submitter&.kill&.join
    end

    def test_forced_remote_execution_does_not_wait_for_ownership
      @scheduler = Scheduler.new(queue: @queue)
      submitter = Thread.new { @scheduler.execute(auto_local: false) { nil } }
      Timeout.timeout(2) { @queue.pop }.to_proc.call

      assert submitter.join(2)
      assert_same @scheduler, submitter.value
      assert_nil @scheduler.owner
    ensure
      submitter&.kill&.join
    end

    def test_raise_mode_accepts_shareable_arguments
      result = Queue.new
      submitter = Thread.new do
        @scheduler.execute(:done, result, mode: :raise, auto_local: false) { |value, output| output << value }
      end
      Timeout.timeout(2) { @queue.pop }.to_proc.call

      assert submitter.join(2)
      assert_same @scheduler, submitter.value
      assert_equal :done, result.pop
    ensure
      submitter&.kill&.join
    end

    def test_raise_mode_rejects_unshareable_arguments
      return unless Internal.native_ractors?
      assert_raises(Ractor::IsolationError) do
        @scheduler.execute(Object.new, mode: :raise, auto_local: false) { nil }
      end
      assert_equal 0, @queue.size
    end

    def test_make_shareable_mode_freezes_the_original_argument
      return unless Internal.native_ractors?
      source = [:original]
      execute_transferred_argument(source, :make_shareable)

      assert_predicate source, :frozen?
      assert Ractor.shareable?(source)
    end

    def test_shareable_copy_mode_preserves_the_original_argument
      return unless Internal.native_ractors?
      source = [:original]
      execute_transferred_argument(source, :shareable_copy)

      refute_predicate source, :frozen?
    end

    def test_move_mode_transfers_the_argument
      return unless Internal.native_ractors?
      source = [:original]
      execute_transferred_argument(source, :move)
      assert_raises(Ractor::MovedError) { source.size }
    end

    def test_close_rejects_execution_waiting_for_ownership
      @scheduler = Scheduler.new(queue: @queue)
      started = Thread::Queue.new
      submitter = Thread.new do
        started << true
        @scheduler.execute { raise "executed after close" }
      rescue SchedulerClosedError => e
        e
      end
      started.pop
      Timeout.timeout(2) { Thread.pass until submitter.status == "sleep" }
      @scheduler.close

      assert submitter.join(2), "execute remained blocked after close"
      assert_instance_of SchedulerClosedError, submitter.value
    ensure
      submitter&.kill&.join
    end

    def test_execution_on_another_ractor
      result = Queue.new
      remote = Ractor.new(@queue) do |queue|
        queue.pop.to_proc.call
        :done
      end
      @scheduler = Scheduler.new(queue: @queue)
      @scheduler.owner = remote
      returned = Timeout.timeout(5) do
        @scheduler.execute(result) { |output| output << Ractor.current }
      end

      assert_same @scheduler, returned
      assert_same remote, result.pop
      assert_equal :done, ractor_value(remote)
    ensure
      @queue&.close
    end

    private

    def execute_transferred_argument(source, mode)
      result = Queue.new
      submitter = Thread.new do
        @scheduler.execute(source, result, mode:, auto_local: false) do |data, output|
          output << data[0]
        end
      end
      Timeout.timeout(2) { @queue.pop }.to_proc.call

      assert submitter.join(2), "execute did not return after transfer"
      assert_same @scheduler, submitter.value
      assert_equal :original, result.pop
    ensure
      submitter&.kill&.join
    end
  end
end
