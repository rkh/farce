# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestThreadScheduler < Test
    def setup
      @scheduler = ThreadScheduler.new
    end

    def test_construction_starts_no_threads_or_freezes_configuration
      output, error, status = ruby_isolated(<<~RUBY)
        require "farce"
        threads = Thread.list
        scheduler = Farce::ThreadScheduler.new
        abort "started a thread" unless Thread.list == threads
        abort "configuration frozen" if Farce.config.frozen?
        unless Farce::Ractor.builtin?
          abort "wrong main scheduler" unless Farce.on_main.is_a?(Farce::ThreadScheduler)
        end
        puts "idle"
      RUBY

      assert_predicate status, :success?, error
      assert_equal "idle\n", output
      assert_empty error
    end

    def test_schedule_starts_a_new_thread_for_each_task_and_returns_before_completion
      started = Thread::Queue.new
      release = Thread::Queue.new
      workers = []
      values = []
      caller_self = self
      2.times do
        returned = @scheduler.schedule(values, mode: :move, auto_local: false) do |array|
          started << [Thread.current, self, array]
          release.pop
        end

        assert_same @scheduler, returned
        worker, receiver, argument = Timeout.timeout(5) { started.pop }
        workers << worker

        refute_same Thread.current, worker
        assert_same caller_self, receiver
        assert_same values, argument
        assert_predicate worker, :alive?
      end

      refute_same workers[0], workers[1]
    ensure
      release&.close
      workers&.each { it.join(5) || it.kill.join }
    end

    def test_execute_preserves_arguments_binding_thread_and_fiber
      values = []
      caller_self = self
      caller_thread = Thread.current
      caller_fiber = Fiber.current
      returned = @scheduler.execute(values, :done, mode: :move, auto_local: false) do |array, value|
        assert_same values, array
        assert_same caller_self, self
        assert_same caller_thread, Thread.current
        assert_same caller_fiber, Fiber.current
        array << value
      end

      assert_same @scheduler, returned
      assert_equal [:done], values
    end

    def test_execute_propagates_exceptions
      failure = ArgumentError.new("task failed")

      assert_same failure, assert_raises(ArgumentError) { @scheduler.execute { raise failure } }
    end

    def test_execute_requires_a_block
      assert_raises(LocalJumpError) { @scheduler.execute }
    end

    def test_schedule_requires_a_block
      assert_raises(ThreadError) { @scheduler.schedule }
    end

    def test_stateless_scheduler_is_shareable_and_close_is_a_noop
      assert Ractor.shareable?(@scheduler)
      assert_predicate @scheduler, :local?
      assert_same @scheduler, @scheduler.close
      refute_predicate @scheduler, :closed?
      assert_equal :running, @scheduler.state
      assert_same(@scheduler, @scheduler.execute { :still_available })
    end

    def test_shared_scheduler_executes_in_the_calling_ractor
      ready = Queue.new
      remote = Ractor.new(@scheduler, ready) do |scheduler, output|
        returned = scheduler.execute(output) { |queue| queue << Ractor.current }
        scheduler.equal?(returned)
      end

      assert_same remote, ready.pop(timeout: 5)
      assert remote.respond_to?(:value) ? remote.value : remote.take
    end
  end
end
