# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "test_unshared_scheduler"

module Farce
  class TestLocalScheduler < TestUnsharedScheduler
    class YieldingScheduler < Local::Scheduler
      def initialize(ready:, release:, **, &)
        @ready = ready
        @release = release
        @pause = Internal::Flag.new(false)
        super(**, &)
      end

      def pause_initialization = @pause.set

      private

      def new_scoped_value(...)
        if @pause.value
          @ready << :constructing
          @release.pop
        end
        super
      end
    end

    def self.wait_for_close(scheduler)
      deadline = Clock.now + 5
      until scheduler.state == :closed
        raise "scheduler did not close" if Clock.now >= deadline
        sleep 0.001
      end
    end

    def test_initialization
      scheduler = scheduler_class.new

      assert_equal :initialized, scheduler.state
      assert_equal :ractor, scheduler.scope
      assert_same Ractor.current, scheduler.owner
      assert_predicate scheduler, :local?
      assert scheduler.local?(wait: false)
      assert_nil scheduler.error
      assert_nil scheduler.external_scheduler
      refute_predicate scheduler, :alive?
      refute_predicate scheduler, :closed?
      refute_predicate scheduler, :wraps_external?
      assert_predicate scheduler, :ractor_shareable?
      assert Ractor.shareable?(scheduler)
      assert_instance_of Unshared::Scheduler, backend_scheduler(scheduler)
      assert_instance_of Internal::UnsharedQueue, backend_scheduler(scheduler).instance_variable_get(:@queue)
    ensure
      scheduler&.close_all
    end

    def test_new_starts_no_background_threads
      output, error, status = ruby_isolated(<<~RUBY)
        require "farce"
        threads = Thread.list
        Farce::SCOPES.each do |scope|
          scheduler = Farce::Local::Scheduler.new(scope: scope)
          abort "scheduler started" unless scheduler.state == :initialized
          abort "started a background thread" unless Thread.list == threads
          scheduler.close_all
        end
        puts "idle"
      RUBY

      assert_predicate status, :success?, error
      assert_equal "idle\n", output
      assert_empty error
    end

    def test_first_launch_can_happen_in_another_ractor
      output, error, status = ruby_isolated(<<~RUBY)
        require "farce"
        scheduler = Farce::Local::Scheduler.new
        caller = Farce::Ractor.new(scheduler) do |local|
          results = Farce::Unshared::Queue.new
          worker = local.launch_thread
          local.schedule { results << :done }
          value = results.pop(timeout: 5)
          local.close
          worker.join
          value
        end
        value = caller.respond_to?(:value) ? caller.value : caller.take
        abort "task did not run" unless value == :done
        abort "creator was launched" unless scheduler.state == :initialized
        scheduler.close_all
        puts "ok"
      RUBY

      assert_predicate status, :success?, error
      assert_equal "ok\n", output
      assert_empty error
    end

    def test_current_returns_the_installed_scheduler_across_fiber_scopes
      scheduler = nil
      return unless Fiber.respond_to?(:set_scheduler)
      %i[thread fiber fiber_storage].each do |scope|
        scheduler = scheduler_class.new(scope:)
        Fiber.set_scheduler(scheduler)
        installed = scheduler_class.current
        results = []
        Fiber.schedule do
          results << scheduler_class.current
          scheduler_class.current.close
        end
        Fiber.set_scheduler(nil)

        assert_instance_of Unshared::Scheduler, installed
        assert_equal [installed], results
        assert_equal :closed, scheduler.state
      end
    ensure
      scheduler&.close_all
      Fiber.set_scheduler(nil) if Fiber.respond_to?(:scheduler) && Fiber.scheduler
    end

    def test_ractor_transfer_contract
      scheduler = scheduler_class.new

      assert Ractor.shareable?(scheduler)
      assert_predicate scheduler, :ractor_shareable?
      assert_equal :ractor, scheduler.scope
    ensure
      scheduler&.close_all
    end

    def test_constructor_respects_ractor_boundary
      return super unless Internal.native_ractors?
      constructors = Unshared::Queue.new

      assert_raises(Ractor::IsolationError) do
        scheduler_class.new do
          constructors << Thread.current
          Helpers::Internal::FiberScheduler.new
        end
      end
    end

    def test_new_remains_unstarted_in_other_ractors_after_manual_launch
      scheduler = scheduler_class.new
      worker = scheduler.launch_thread
      caller = Ractor.new(scheduler) do |local|
        before = local.state
        results = Unshared::Queue.new
        local.schedule { results << :done }
        after_submission = local.state
        thread = local.launch_thread
        value = results.pop(timeout: 5)
        local.close
        thread.join
        [before, after_submission, value, local.state]
      end

      assert_equal %i[initialized initialized done closed], ractor_value(caller)
      assert_equal :running, scheduler.state
    ensure
      scheduler&.close_all
      worker&.join(5) || worker&.kill&.join
    end

    def test_create_starts_independent_workers_in_every_ractor
      scheduler = scheduler_class.create
      caller = Ractor.new(scheduler) do |local|
        before = local.state
        results = Unshared::Queue.new
        values = []
        owner = Ractor.current
        local.schedule(values) { |data| results << [data.equal?(values), Ractor.current == owner] }
        result = results.pop(timeout: 5)
        local.close
        TestLocalScheduler.wait_for_close(local)
        [before, result, local.state]
      end

      assert_equal [:running, [true, true], :closed], ractor_value(caller)
      assert_equal :running, scheduler.state
      refute_predicate scheduler, :closed?
    ensure
      scheduler&.close_all
      TestLocalScheduler.wait_for_close(scheduler) if scheduler
    end

    def test_create_retains_worker_options_for_other_scopes
      return unless Fiber.respond_to?(:set_scheduler)
      events = Queue.new
      constructor = Ractor.shareable_proc do
        events << [Thread.current.name, Thread.current.priority].freeze
        Helpers::Internal::FiberScheduler.new
      end
      scheduler = scheduler_class.create(name: "scoped-worker", priority: 1, &constructor)
      caller = Ractor.new(scheduler) do |local|
        local.state
        local.close
        TestLocalScheduler.wait_for_close(local)
      end

      2.times { assert_equal ["scoped-worker", 1], events.pop(timeout: 5) }
      ractor_value(caller)
    ensure
      scheduler&.close_all
      TestLocalScheduler.wait_for_close(scheduler) if scheduler
    end

    def test_close_is_independent_between_ractors
      scheduler = scheduler_class.create
      scheduler.close
      TestLocalScheduler.wait_for_close(scheduler)
      caller = Ractor.new(scheduler) do |local|
        results = Unshared::Queue.new
        before = local.closed?
        local.schedule { results << :done }
        value = results.pop(timeout: 5)
        local.close
        TestLocalScheduler.wait_for_close(local)
        [before, value]
      end

      assert_equal [false, :done], ractor_value(caller)
      assert_predicate scheduler, :closed?
    ensure
      scheduler&.close_all
    end

    def test_close_rejects_submissions_before_validating_their_arguments
      scheduler = scheduler_class.new
      scheduler.close

      assert_raises(SchedulerClosedError) { scheduler.schedule }
      assert_raises(SchedulerClosedError) { scheduler.schedule(mode: :copy, auto_local: false) { nil } }
    ensure
      scheduler&.close_all
    end

    def test_close_all_allows_running_tasks_to_finish_in_every_ractor
      scheduler = scheduler_class.create
      release = Queue.new
      results = Unshared::Queue.new
      scheduler.schedule do
        results << :started
        Fiber.new(blocking: true) { release.pop }.resume
        results << :done
      end
      events = Queue.new
      caller = Ractor.new(scheduler, release, events) do |local, gate, output|
        finished = Unshared::Queue.new
        local.schedule do
          output << :started
          Fiber.new(blocking: true) { gate.pop }.resume
          finished << :done
        end
        value = finished.pop(timeout: 5)
        TestLocalScheduler.wait_for_close(local)
        [value, local.state]
      end

      assert_equal :started, results.pop(timeout: 5)
      assert_equal :started, events.pop(timeout: 5)
      scheduler.close_all
      2.times { release << :continue }

      assert_equal :done, results.pop(timeout: 5)
      assert_equal %i[done closed], ractor_value(caller)
      TestLocalScheduler.wait_for_close(scheduler)

      assert_equal :closed, scheduler.state
    ensure
      release&.close
      scheduler&.close_all
      TestLocalScheduler.wait_for_close(scheduler) if scheduler
    end

    def test_close_all_releases_blocked_submissions_and_drains_other_ractors
      return unless Fiber.respond_to?(:set_scheduler)
      scheduler = scheduler_class.create(capacity: 1)
      events = Queue.new
      release = Queue.new
      caller = Ractor.new(scheduler, events, release) do |local, output, gate|
        local.schedule do
          output << :started
          Fiber.new(blocking: true) { gate.pop }.resume
          output << :released
        end
        local.schedule { output << :drained }
        submitter = Thread.new do
          local.schedule { nil }
        rescue SchedulerClosedError
          output << :rejected
        end
        queue = Internal::Storage[local].instance_variable_get(:@queue)
        deadline = Clock.now + 5
        until queue.num_waiting.positive?
          raise "submission did not block" if Clock.now >= deadline
          Thread.pass
        end
        output << :blocked
        submitter.join
        TestLocalScheduler.wait_for_close(local)
        local.state
      end

      assert_equal %i[blocked started], [events.pop(timeout: 5), events.pop(timeout: 5)].sort
      assert_same scheduler, scheduler.close_all
      assert_same scheduler, scheduler.close_all
      assert_predicate scheduler, :closed?
      assert_raises(SchedulerClosedError) { scheduler.schedule { nil } }
      assert_equal :rejected, events.pop(timeout: 5)
      release << :continue

      assert_equal %i[drained released], [events.pop(timeout: 5), events.pop(timeout: 5)].sort
      assert_equal :closed, ractor_value(caller)
      future = Ractor.new(scheduler) do |local|
        rejected = begin
          local.schedule { nil }
          false
        rescue SchedulerClosedError
          true
        end
        [local.state, local.closed?, local.alive?, rejected]
      end

      assert_equal [:closed, true, false, true], ractor_value(future)
    ensure
      release&.close
      scheduler&.close_all
      TestLocalScheduler.wait_for_close(scheduler) if scheduler
    end

    def test_close_all_releases_unlaunched_remote_submissions
      scheduler = scheduler_class.new(capacity: 1)
      events = Queue.new
      caller = Ractor.new(scheduler, events) do |local, output|
        local.schedule { nil }
        submitter = Thread.new do
          local.schedule { nil }
        rescue SchedulerClosedError
          output << :rejected
        end
        queue = Internal::Storage[local].instance_variable_get(:@queue)
        deadline = Clock.now + 5
        until queue.num_waiting.positive?
          raise "submission did not block" if Clock.now >= deadline
          Thread.pass
        end
        output << :blocked
        submitter.join
        [local.state, local.closed?, local.alive?]
      end

      assert_equal :blocked, events.pop(timeout: 5)
      scheduler.close_all

      assert_equal :rejected, events.pop(timeout: 5)
      assert_equal [:closing, true, false], ractor_value(caller)
    ensure
      scheduler&.close_all
    end

    def test_close_all_during_scoped_worker_construction
      return unless Fiber.respond_to?(:set_scheduler)
      started = Queue.new
      release = Queue.new
      constructor = Ractor.shareable_proc do
        unless Ractor.main?
          started << :constructing
          Fiber.new(blocking: true) { release.pop }.resume
        end
        Helpers::Internal::FiberScheduler.new
      end
      scheduler = scheduler_class.create(&constructor)
      caller = Ractor.new(scheduler) do |local|
        local.state
        rejected = begin
          local.schedule { nil }
          false
        rescue SchedulerClosedError
          true
        end
        TestLocalScheduler.wait_for_close(local)
        rejected
      end

      assert_equal :constructing, started.pop(timeout: 5)
      scheduler.close_all
      release << :continue

      assert ractor_value(caller)
    ensure
      release&.close
      scheduler&.close_all
      TestLocalScheduler.wait_for_close(scheduler) if scheduler
    end

    def test_supported_scopes_and_invalid_scopes
      Farce::SCOPES.each do |scope|
        scheduler = scheduler_class.new(scope:)

        assert_equal scope, scheduler.scope
        assert_equal :initialized, scheduler.state
        assert_predicate scheduler, :local?
        scheduler.close_all
        created = scheduler_class.create(scope:)

        assert_equal :running, created.state
        created.close_all
        TestLocalScheduler.wait_for_close(created)
      end

      [:global, :invalid, "thread", nil, Thread].each do |scope|
        assert_raises(ArgumentError) { scheduler_class.new(scope:) }
      end
    end

    def test_thread_scope_keeps_new_schedulers_unstarted
      scheduler = scheduler_class.new(scope: :thread)
      first = backend_scheduler(scheduler)
      scheduler.close
      other = Thread.new do
        before = scheduler.state
        same = first.equal?(backend_scheduler(scheduler))
        scheduler.close
        [before, same, scheduler.closed?]
      end

      assert_equal [:initialized, false, true], other.value
      assert_predicate scheduler, :closed?
    ensure
      scheduler&.close_all
    end

    def test_create_and_close_all_reach_multiple_thread_scopes
      scheduler = scheduler_class.create(scope: :thread)
      ready = Thread::Queue.new
      release = Thread::Queue.new
      threads = 2.times.map do
        Thread.new do
          before = scheduler.state
          ready << true
          release.pop
          TestLocalScheduler.wait_for_close(scheduler)
          [before, scheduler.state]
        end
      end
      2.times { ready.pop }
      scheduler.close_all
      2.times { release << true }

      assert_equal [%i[running closed], %i[running closed]], threads.map(&:value)
      future = Thread.new { [scheduler.closed?, scheduler.state, scheduler.alive?] }

      assert_equal [true, :closed, false], future.value
    ensure
      2.times { release&.push(true) }
      scheduler&.close_all
      threads&.each { it.join(5) || it.kill.join }
      TestLocalScheduler.wait_for_close(scheduler) if scheduler
    end

    def test_fiber_and_thread_group_scopes_have_independent_lifecycles
      scheduler = nil
      %i[fiber thread_group].each do |scope|
        scheduler = scheduler_class.new(scope:)
        scheduler.close
        access = lambda do
          before = scheduler.state
          worker = scheduler.launch_thread
          scheduler.close
          worker.join
          [before, scheduler.state]
        end
        other = if scope == :fiber
                  Fiber.new(&access).resume
                else
                  Thread.new do
                    ThreadGroup.new.add(Thread.current)
                    access.call
                  end.value
                end

        assert_equal %i[initialized closed], other
        assert_predicate scheduler, :closed?
        scheduler.close_all
      end
    ensure
      scheduler&.close_all
    end

    def test_fiber_storage_inherits_the_scheduler_and_allows_a_separate_scope
      scheduler = scheduler_class.new(scope: :fiber_storage)
      first = backend_scheduler(scheduler)

      assert_same first, Fiber.new { backend_scheduler(scheduler) }.resume
      other = Fiber.new(storage: {}) { backend_scheduler(scheduler) }.resume

      refute_same first, other
      assert_equal :initialized, other.state
      scheduler.close_all
      future = Fiber.new(storage: {}) { [scheduler.closed?, scheduler.state] }.resume

      assert_equal [true, :closed], future
    end

    def test_scoped_initialization_is_serialized_between_scheduled_fibers
      return unless Fiber.respond_to?(:set_scheduler)
      started = Queue.new
      release = Queue.new
      scheduler = YieldingScheduler.new(scope: :thread, ready: started, release:)
      scheduler.pause_initialization
      requested = Thread::Queue.new
      instances = Thread::Queue.new
      worker = Thread.new do
        Fiber.set_scheduler(Helpers::Internal::FiberScheduler.new)
        Fiber.schedule do
          scheduler.state
          instances << Internal::Storage[scheduler, scope: :thread]
        end
        Fiber.schedule do
          requested << true
          scheduler.state
          instances << Internal::Storage[scheduler, scope: :thread]
        end
        Fiber.set_scheduler(nil)
      end

      assert_equal :constructing, started.pop(timeout: 5)
      requested.pop
      release << true
      release << true

      assert worker.join(5), "scoped scheduler initialization did not finish"
      assert_same instances.pop, instances.pop
    ensure
      release&.close
      scheduler&.close_all
      worker&.join(5) || worker&.kill&.join
    end

    def test_inspection_describes_the_current_scope
      scheduler = scheduler_class.new(scope: :thread)

      assert_match(/Farce::Local::Scheduler/, scheduler.inspect)
      assert_match(/scope=:thread/, scheduler.inspect)
      assert_match(/state=:initialized/, scheduler.inspect)
    ensure
      scheduler&.close_all
    end

    private

    def scheduler_class = Local::Scheduler
    def current_scheduler_class = Unshared::Scheduler

    def backend_scheduler(scheduler)
      scheduler.state
      Internal::Storage[scheduler, scope: scheduler.scope]
    end
  end
end
