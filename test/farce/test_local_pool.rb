# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "test_unshared_pool"

module Farce
  class TestLocalPool < TestUnsharedPool
    class YieldingPool < Local::Pool
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

    def self.wait_for_close(pool)
      deadline = Clock.now + 5
      until pool.state == :closed
        raise "pool did not close" if Clock.now >= deadline
        sleep 0.001
      end
    end

    def test_ractor_transfer_contract
      pool = pool_class.new

      assert Ractor.shareable?(pool)
      assert_predicate pool, :ractor_shareable?
      assert_equal :ractor, pool.scope
    ensure
      pool&.close_all
      close_pool(pool)
    end

    def test_scheduler_constructor_respects_ractor_boundary
      return unless Internal.native_ractors?
      constructors = Unshared::Queue.new

      assert_raises(Ractor::IsolationError) do
        pool_class.new(min_size: 1) do
          constructors << Thread.current
          Helpers::Internal::FiberScheduler.new
        end
      end
    end

    def test_each_ractor_runs_tasks_on_its_own_threads
      pool = pool_class.new(max_size: 1, shrink_after: nil)
      output = Queue.new
      parent_ractor = Ractor.current
      pool.schedule { output << Ractor.current }
      remote = Ractor.new(pool, output) do |local, results|
        before = local.size
        caller_thread = Thread.current
        caller_ractor = Ractor.current
        completed = Unshared::Queue.new
        local.schedule do
          completed << [Thread.current != caller_thread, Ractor.current == caller_ractor]
        end
        results << Ractor.make_shareable([before, completed.pop, local.size, local.local?])
        local.close
        TestLocalPool.wait_for_close(local)
        :done
      end

      assert_same parent_ractor, output.pop(timeout: 2)
      assert_equal [0, [true, true], 1, true], output.pop(timeout: 2)
      assert_equal :done, ractor_value(remote)
      assert_equal 1, pool.size
      refute_predicate pool, :closed?
    ensure
      pool&.close_all
      close_pool(pool)
    end

    def test_growth_keeps_workers_and_supervision_in_the_owning_ractor
      pool = pool_class.new(max_size: 2, max_inflight: 1, grow_after: 0.005, shrink_after: nil)
      remote = Ractor.new(pool) do |local|
        results = Unshared::Queue.new
        release = Unshared::Queue.new
        owner = Ractor.current
        local.schedule do
          results << [Thread.current, Ractor.current == owner]
          Fiber.new(blocking: true) { release.pop }.resume
        end
        first, first_local = results.pop(timeout: 2)
        local.schedule { results << [Thread.current, Ractor.current == owner] }
        second, second_local = results.pop(timeout: 2)
        result = [first_local, second_local, first != second, local.size]
        release << :continue
        local.close
        TestLocalPool.wait_for_close(local)
        result
      end

      assert_equal [true, true, true, 2], ractor_value(remote)
    ensure
      pool&.close_all
      close_pool(pool)
    end

    def test_close_is_independent_in_each_ractor
      pool = pool_class.new(shrink_after: nil)
      pool.close
      remote = Ractor.new(pool) do |local|
        results = Unshared::Queue.new
        before = local.closed?
        local.schedule { results << :done }
        result = results.pop(timeout: 2)
        local.close
        TestLocalPool.wait_for_close(local)
        [before, result]
      end

      assert_equal [false, :done], ractor_value(remote)
      assert_predicate pool, :closed?
    ensure
      pool&.close_all
      close_pool(pool)
    end

    def test_close_all_drains_every_ractor_and_rejects_future_ractors
      pool = pool_class.new(max_size: 2, max_inflight: 1, grow_after: 60, shrink_after: nil)
      output = Queue.new
      release = Queue.new
      remote = Ractor.new(pool, output, release) do |local, events, gate|
        local.schedule do
          events << :started
          Fiber.new(blocking: true) { gate.pop }.resume
          events << :released
        end
        local.schedule { events << :drained }
        events << :queued
        Ractor.receive
        rejected = begin
          local.schedule { nil }
          false
        rescue PoolClosedError
          true
        end
        TestLocalPool.wait_for_close(local)
        [rejected, local.size]
      end

      assert_equal %i[queued started], [output.pop(timeout: 2), output.pop(timeout: 2)].sort
      assert_same pool, pool.close_all
      assert_same pool, pool.close_all
      assert_predicate pool, :closed?
      assert_raises(PoolClosedError) { pool.schedule { nil } }
      remote.send(:check)
      release << :continue

      assert_equal %i[drained released], [output.pop(timeout: 2), output.pop(timeout: 2)].sort
      assert_equal [true, 0], ractor_value(remote)
      future = Ractor.new(pool) do |local|
        rejected = begin
          local.schedule { nil }
          false
        rescue PoolClosedError
          true
        end
        [local.state, local.size, local.closed?, rejected]
      end

      assert_equal [:closed, 0, true, true], ractor_value(future)
    ensure
      release&.close
      pool&.close_all
      close_pool(pool)
    end

    def test_close_all_releases_remote_submissions_blocked_by_capacity
      pool = pool_class.new(max_size: 2, max_inflight: 1, capacity: 1, grow_after: 60, shrink_after: nil)
      output = Queue.new
      release = Queue.new
      remote = Ractor.new(pool, output, release) do |local, events, gate|
        local.schedule do
          events << :started
          Fiber.new(blocking: true) { gate.pop }.resume
        end
        local.schedule { nil }
        submitter = Thread.new do
          local.schedule { nil }
        rescue PoolClosedError
          events << :rejected
        end
        queue = Internal::Storage[local].instance_variable_get(:@queue)
        deadline = Clock.now + 5
        until queue.num_waiting.positive?
          raise "submission did not block" if Clock.now >= deadline
          Thread.pass
        end
        events << :blocked
        submitter.join
        TestLocalPool.wait_for_close(local)
        :done
      end

      assert_equal %i[blocked started], [output.pop(timeout: 2), output.pop(timeout: 2)].sort
      pool.close_all

      assert_equal :rejected, output.pop(timeout: 2)
      release << :continue

      assert_equal :done, ractor_value(remote)
    ensure
      release&.close
      pool&.close_all
      close_pool(pool)
    end

    def test_close_all_during_new_ractor_initialization
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
      pool = pool_class.new(max_size: 1, min_size: 1, shrink_after: nil, &constructor)
      remote = Ractor.new(pool) do |local|
        local.size
        rejected = begin
          local.schedule { nil }
          false
        rescue PoolClosedError
          true
        end
        TestLocalPool.wait_for_close(local)
        [rejected, local.size]
      end

      assert_equal :constructing, started.pop(timeout: 2)
      pool.close_all
      release << :continue

      assert_equal [true, 0], ractor_value(remote)
    ensure
      release&.close
      pool&.close_all
      close_pool(pool)
    end

    def test_supported_scopes_and_invalid_scopes
      Farce::SCOPES.each do |scope|
        pool = pool_class.new(scope:)

        assert_equal scope, pool.scope
        assert_predicate pool, :local?
        assert_equal :running, pool.state
        assert_same pool, pool.close_all
      end
      [:global, :invalid, "thread", nil, Thread].each do |scope|
        assert_raises(ArgumentError) { pool_class.new(scope:) }
      end
    end

    def test_thread_scope_shares_fibers_and_separates_threads
      pool = pool_class.new(scope: :thread, min_size: 1, max_size: 1, shrink_after: nil)
      parent = Internal::Storage[pool, scope: :thread]

      assert_same parent, Fiber.new {
        pool.size
        Internal::Storage[pool, scope: :thread]
      }.resume
      pool.close
      other = Thread.new do
        results = Unshared::Queue.new
        before = pool.closed?
        pool.schedule { results << :done }
        result = [before, results.pop(timeout: 2)]
        pool.close
        TestLocalPool.wait_for_close(pool)
        result
      end

      assert_equal [false, :done], other.value
      assert_predicate pool, :closed?
    ensure
      pool&.close_all
      close_pool(pool)
    end

    def test_fiber_and_thread_group_scopes_have_independent_lifecycles
      pool = nil
      %i[fiber thread_group].each do |scope|
        pool = pool_class.new(scope:, max_size: 1, shrink_after: nil)
        pool.close
        access = lambda do
          result = Unshared::Queue.new
          before = pool.closed?
          pool.schedule { result << :done }
          [before, result.pop(timeout: 2)]
        end
        other = if scope == :fiber
                  Fiber.new(&access).resume
                else
                  Thread.new do
                    ThreadGroup.new.add(Thread.current)
                    access.call
                  end.value
                end

        assert_equal [false, :done], other
        assert_predicate pool, :closed?
        pool.close_all
      end
    ensure
      pool&.close_all
      close_pool(pool)
    end

    def test_fiber_storage_inherits_the_pool_and_can_start_an_independent_scope
      pool = pool_class.new(scope: :fiber_storage)
      pool.close

      assert Fiber.new { pool.closed? }.resume
      isolated = Fiber.new(storage: {}) { [pool.closed?, pool.scope] }.resume

      assert_equal [false, :fiber_storage], isolated
      pool.close_all
      future = Fiber.new(storage: {}) { [pool.closed?, pool.state, pool.size] }.resume

      assert_equal [true, :closed, 0], future
    ensure
      pool&.close_all
      close_pool(pool)
    end

    def test_close_all_reaches_multiple_pools_in_one_ractor
      pool = pool_class.new(scope: :thread, min_size: 1, max_size: 1, shrink_after: nil)
      ready = Thread::Queue.new
      release = Thread::Queue.new
      threads = 2.times.map do
        Thread.new do
          pool.size
          ready << true
          release.pop
          TestLocalPool.wait_for_close(pool)
          [pool.closed?, pool.size]
        end
      end
      2.times { ready.pop }
      pool.close_all
      2.times { release << true }

      assert_equal [[true, 0], [true, 0]], threads.map(&:value)
      assert_predicate pool, :closed?
      assert_equal [true, :closed, 0], Thread.new { [pool.closed?, pool.state, pool.size] }.value
    ensure
      2.times { release&.push(true) }
      pool&.close_all
      threads&.each { it.join(2) }
      close_pool(pool)
    end

    def test_first_use_in_a_thread_scope_is_serialized_between_scheduled_fibers
      return unless Fiber.respond_to?(:set_scheduler)
      calls = Counter.new
      started = Queue.new
      release = Queue.new
      pool = YieldingPool.new(scope: :thread, min_size: 1, max_size: 1, shrink_after: nil,
        ready: started, release:) do
        calls.increment
        Helpers::Internal::FiberScheduler.new
      end
      pool.pause_initialization
      second = Thread::Queue.new
      worker = Thread.new do
        Fiber.set_scheduler(Helpers::Internal::FiberScheduler.new)
        Fiber.schedule { pool.size }
        Fiber.schedule do
          second << :requested
          pool.size
        end
        Fiber.set_scheduler(nil)
        pool.close
        TestLocalPool.wait_for_close(pool)
      end

      assert_equal :constructing, started.pop(timeout: 2)
      assert_equal :requested, second.pop
      release << :continue
      # Release a duplicate constructor too so a failure cannot strand a thread.
      release << :continue

      assert worker.join(5), "scoped pool initialization did not finish"
      assert_equal 2, calls.value
    ensure
      release&.close
      pool&.close_all
      worker&.join(2)
      close_pool(pool)
    end

    private

    def pool_class = Local::Pool
  end
end
