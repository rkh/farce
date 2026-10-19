# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "timeout"

module Farce
  class TestPoolTuning < Test
    def test_settings_are_writable_and_invalid_changes_preserve_previous_values
      pool = pool_class.new
      pool.min_size = 1
      pool.max_size = 2
      pool.max_inflight = nil
      pool.grow_after = 0
      pool.shrink_after = nil

      assert_equal [1, 2, nil, 0, nil], [pool.min_size, pool.max_size, pool.max_inflight,
                                         pool.grow_after, pool.shrink_after]
      assert_raises(ArgumentError) { pool.max_size = 0 }
      assert_equal 2, pool.max_size
      assert_raises(ArgumentError) { pool.min_size = 3 }
      assert_equal 1, pool.min_size
    ensure
      close_pool(pool)
    end

    def test_changing_idle_timeout_wakes_an_idle_worker
      pool = pool_class.new(max_size: 1, shrink_after: nil)
      events = Queue.new
      pool.schedule(events) { |queue| queue << :done }

      assert_equal :done, events.pop(timeout: 5)
      pool.shrink_after = 0.01
      Timeout.timeout(5) { sleep 0.001 until pool.size.zero? } # rubocop:disable Style/ZeroLengthPredicate

      assert_equal 0, pool.size
    ensure
      close_pool(pool)
    end

    def test_pending_capacity_can_be_resized
      pool = pool_class.new(capacity: 1)
      pool.capacity = 3

      assert_equal 3, pool.capacity
    ensure
      close_pool(pool)
    end

    def test_increasing_minimum_starts_workers_immediately
      pool = pool_class.new(max_size: 3, shrink_after: nil)
      pool.min_size = 2

      assert_equal 2, pool.size
      assert_nil pool.error
    ensure
      close_pool(pool)
    end

    def test_lowering_maximum_retires_idle_workers_without_an_idle_timeout
      pool = pool_class.new(min_size: 3, max_size: 3, shrink_after: nil)
      pool.min_size = 0
      pool.max_size = 1
      Timeout.timeout(5) { sleep 0.001 until pool.size == 1 }

      assert_equal 1, pool.size
      assert_nil pool.error
    ensure
      close_pool(pool)
    end

    def test_lowering_maximum_finishes_running_tasks_and_preserves_queued_work
      # Stay below the maximum so the soft inflight limit keeps the workers distinct.
      pool = pool_class.new(min_size: 3, max_size: 4, max_inflight: 1, grow_after: 60, shrink_after: nil)
      events = Queue.new
      release = Queue.new
      3.times do
        pool.schedule(events, release, mode: :raise) do |output, gate|
          output << :started
          Fiber.new(blocking: true) { gate.pop }.resume
          output << :finished
        end
      end

      3.times { assert_equal :started, events.pop(timeout: 5) }
      pool.min_size = 0
      pool.max_size = 1

      assert_equal 3, pool.size
      pool.schedule(events, mode: :raise) { |output| output << :queued }
      3.times { release << true }
      results = 4.times.map { events.pop(timeout: 5) }

      assert_equal %i[finished finished finished queued], results.sort
      Timeout.timeout(5) { sleep 0.001 until pool.size == 1 }

      assert_equal 1, pool.size
      assert_nil pool.error
    ensure
      3.times { release << true } if release && !release.closed?
      close_pool(pool)
      release&.close
    end

    def test_downsizing_does_not_block_work_needed_by_running_tasks
      pool = pool_class.new(min_size: 2, max_size: 2, shrink_after: nil)
      events = Queue.new
      release = Queue.new
      completion = Queue.new
      2.times do
        pool.schedule(events, release, completion, mode: :raise) do |output, gate, finished|
          output << :started
          Fiber.new(blocking: true) { gate.pop }.resume
          finished.pop
          output << :finished
        end
      end

      2.times { assert_equal :started, events.pop(timeout: 5) }
      pool.min_size = 0
      pool.max_size = 1
      2.times { pool.schedule(completion, mode: :raise) { |finished| finished << true } }
      2.times { release << true }

      2.times { assert_equal :finished, events.pop(timeout: 2) }
      Timeout.timeout(5) { sleep 0.001 until pool.size == 1 }

      assert_equal 1, pool.size
    ensure
      2.times { release << true } if release && !release.closed?
      2.times { completion << true } if completion && !completion.closed?
      close_pool(pool)
      release&.close
      completion&.close
    end

    def test_shortening_growth_delay_rechecks_existing_queue_pressure
      pool = pool_class.new(max_size: 2, max_inflight: 1, grow_after: 60, shrink_after: nil)
      events = Queue.new
      release = Queue.new
      pool.schedule(events, release, mode: :raise) do |output, gate|
        output << :started
        Fiber.new(blocking: true) { gate.pop }.resume
      end

      assert_equal :started, events.pop(timeout: 5)
      pool.schedule(events, mode: :raise) { |output| output << :grown }
      pool.grow_after = 0

      assert_equal :grown, events.pop(timeout: 5)
      assert_equal 2, pool.size
    ensure
      3.times { release << true } if release && !release.closed?
      close_pool(pool)
      release&.close
    end

    def test_settings_snapshots_preserve_previous_values
      pool = pool_class.new(max_size: 3)
      before = pool.settings
      pool.max_inflight = nil
      after = pool.settings

      assert_predicate before, :frozen?
      assert_predicate after, :frozen?
      assert_equal 64, before.max_inflight
      assert_nil after.max_inflight
      assert_equal before.generation + 1, after.generation
      assert Ractor.shareable?(after)
    ensure
      close_pool(pool)
    end

    def test_changes_from_another_ractor
      return unless pool_class == Pool
      pool = pool_class.new
      caller = Ractor.new(pool) do |target|
        target.max_size = 2
        target.min_size = 1
        target.max_inflight = nil
        target.grow_after = 0
        target.shrink_after = nil
        target.capacity = 2
        :done
      end

      assert_equal :done, caller.respond_to?(:value) ? caller.value : caller.take
      assert_equal [1, 2, nil, 0, nil, 2], [pool.min_size, pool.max_size, pool.max_inflight,
                                            pool.grow_after, pool.shrink_after, pool.capacity]
    ensure
      close_pool(pool)
    end

    def test_local_changes_leave_future_scope_defaults_unchanged
      return unless pool_class == Local::Pool
      pool = pool_class.new(max_size: 3, capacity: 2)
      pool.max_size = 2
      pool.capacity = 4
      caller = Ractor.new(pool) do |target|
        result = [target.max_size, target.capacity]
        target.close
        Ractor.make_shareable(result)
      end

      assert_equal [3, 2], caller.respond_to?(:value) ? caller.value : caller.take
      assert_equal [2, 4], [pool.max_size, pool.capacity]
    ensure
      close_pool(pool)
    end

    def test_concurrent_limit_updates_keep_published_bounds_consistent
      return unless pool_class == Pool
      pool = pool_class.new(min_size: 1, max_size: 2, shrink_after: nil)
      ready = Queue.new
      release = Flag.new
      writers = 2.times.map do |index|
        Ractor.new(pool, ready, release, index) do |target, events, gate, field|
          events << true
          gate.wait_until_set
          500.times do |iteration|
            field.zero? ? target.min_size = iteration % 2 : target.max_size = (iteration % 2) + 1
          end
          :done
        end
      end
      reader = Ractor.new(pool, ready, release) do |target, events, gate|
        events << true
        gate.wait_until_set
        5000.times do
          snapshot = target.settings
          break snapshot unless snapshot.min_size <= snapshot.max_size
        end
      end

      3.times { assert ready.pop(timeout: 5) }
      release.set

      writers.each { |writer| assert_equal :done, writer.respond_to?(:value) ? writer.value : writer.take }

      assert_equal 5000, reader.respond_to?(:value) ? reader.value : reader.take
    ensure
      release&.set
      close_pool(pool)
    end

    class AdmissionProbePool < Pool
      attr_reader :waiting

      def initialize(**)
        @waiting = Queue.new
        super
      end

      def wait_for_admission(generation)
        @waiting << true
        super
      end
    end

    def test_admission_rechecks_a_changed_limit
      [nil, 2].each do |limit|
        pool = AdmissionProbePool.new(max_size: 2, max_inflight: 1, shrink_after: nil)
        worker = Helpers::Internal::PoolWorker.new(pool)
        worker.task_started(pool.settings)
        waiter = Thread.new { worker.wait_for_admission(nil, nil, pool.settings) }

        assert pool.waiting.pop(timeout: 5)
        pool.max_inflight = limit

        assert waiter.join(5), "configuration change failed to wake admission"
        limit.nil? ? assert_nil(waiter.value.max_inflight) : assert_equal(limit, waiter.value.max_inflight)
        worker.task_finished
        close_pool(pool)
      ensure
        waiter&.kill&.join
        close_pool(pool)
      end
    end

    def test_completion_observes_a_limit_enabled_after_the_task_started
      pool = AdmissionProbePool.new(max_size: 2, max_inflight: nil, shrink_after: nil)
      worker = Helpers::Internal::PoolWorker.new(pool)
      worker.task_started(pool.settings)
      pool.max_inflight = 1
      waiter = Thread.new { worker.wait_for_admission(nil, nil, pool.settings) }

      assert pool.waiting.pop(timeout: 5)
      worker.task_finished

      assert waiter.join(5), "task completion failed to wake admission"
      assert_equal 1, waiter.value.max_inflight
    ensure
      waiter&.kill&.join
      close_pool(pool)
    end

    private

    def pool_class = Pool

    def close_pool(pool)
      return unless pool
      pool.close
      Timeout.timeout(5) { sleep 0.001 until pool.state == :closed }
    end
  end

  class TestUnsharedPoolTuning < TestPoolTuning
    private def pool_class = Unshared::Pool
  end

  class TestLocalPoolTuning < TestPoolTuning
    private def pool_class = Local::Pool
  end
end
