# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestLeasePool < Test
    include Helpers::InternalTestHelpers

    POOL_CLASSES = [Farce::LeasePool, Unshared::LeasePool, Local::LeasePool].freeze

    def run(...) = Timeout.timeout(10) { super }

    def teardown
      Fiber.set_scheduler(nil) if Fiber.respond_to?(:scheduler) && Fiber.scheduler
    end

    def test_public_hierarchy
      pool_classes.each { assert_equal Abstract::LeasePool, it.superclass }

      refute_operator Abstract::LeasePool, :<, Abstract::Lease
    end

    def test_constructor_requires_a_factory_and_positive_integer_max_size
      pool_classes.each do |klass|
        assert_raises(ArgumentError) { klass.new(max_size: 1) }
        assert_raises(ArgumentError) { klass.new { Object.new } }
        [nil, 0, -1, 1.0, "1"].each do |max_size|
          assert_raises(ArgumentError) { klass.new(max_size:) { Object.new } }
        end
      end
    end

    def test_pool_starts_empty_and_creates_on_checkout
      pool_classes.each do |klass|
        calls = Counter.new
        pool = klass.new(max_size: 2) do
          calls.increment
          [Object.new.freeze]
        end

        assert_equal 2, pool.max_size
        assert_equal 0, pool.size
        assert_equal 0, pool.available_count
        assert_equal 0, pool.checked_out_count
        assert_equal 0, pool.creating_count
        assert_equal 0, calls.value

        resource = pool.checkout

        assert_equal 1, calls.value
        assert_equal 1, pool.size
        assert_equal 0, pool.available_count
        assert_equal 1, pool.checked_out_count
        assert_equal 0, pool.creating_count
        assert_same pool, pool.checkin(resource)
        assert_equal 1, pool.available_count
        assert_equal 0, pool.checked_out_count
      end
    end

    def test_size_is_independent_of_in_progress_reservation_counter_snapshots
      klass = concrete_pool_class(Unshared)
      pool = klass.new(max_size: 1) { Object.new }
      internal = pool.send(:internal_pool)
      counter = Struct.new(:value)

      internal.instance_variable_set(:@slots, counter.new(0))
      internal.instance_variable_set(:@creating, counter.new(1))

      assert_equal 0, pool.size
    end

    def test_available_resources_are_reused_before_factory_invocation
      pool_classes.each do |klass|
        calls = Counter.new
        pool = klass.new(max_size: 2) do
          calls.increment
          [Object.new.freeze]
        end
        first_token = pool.checkout { it.fetch(0) }
        second_token = pool.checkout { it.fetch(0) }

        assert_same first_token, second_token
        assert_equal 1, calls.value
        assert_equal 1, pool.size
      end
    end

    def test_one_fiber_can_hold_multiple_resources
      pool_classes.each do |klass|
        calls = Counter.new
        pool = klass.new(max_size: 2) do
          calls.increment
          []
        end
        first = pool.checkout
        second = pool.checkout

        assert_equal 2, calls.value
        assert_equal 2, pool.checked_out_count
        assert_same pool, pool.checkin(first)
        assert_same pool, pool.checkin(second)
        assert_equal 2, pool.available_count
      end
    end

    def test_block_checkout_returns_its_result_and_checks_in
      pool_classes.each do |klass|
        pool = klass.new(max_size: 1) { [] }
        result = pool.checkout do |resource|
          resource << :changed
          :result
        end

        assert_equal :result, result
        assert_equal 1, pool.available_count
        assert_equal [:changed], pool.checkout(&:dup)
      end
    end

    def test_block_checkout_can_return_nil_or_false
      pool_classes.each do |klass|
        pool = klass.new(max_size: 1) { Object.new }
        nil_result = pool.checkout { nil }
        false_result = pool.checkout { false }

        assert_nil nil_result
        refute false_result
        assert_equal 1, pool.available_count
      end
    end

    def test_block_checkout_checks_in_after_exception_and_nonlocal_return
      pool_classes.each do |klass|
        pool = klass.new(max_size: 1) { [] }
        failure = RuntimeError.new("failed use")
        raised = assert_raises(RuntimeError) do
          pool.checkout do |resource|
            resource << :exception
            raise failure
          end
        end

        assert_same failure, raised
        assert_equal :returned, return_from_checkout(pool)
        assert_equal %i[exception returned], pool.checkout(&:dup)
      end
    end

    def test_try_checkout_uses_an_idle_resource_without_waiting
      pool_classes.each do |klass|
        pool = klass.new(max_size: 1) { [] }
        pool.checkout { nil }
        result = pool.try_checkout do |resource|
          resource << :used
          :result
        end

        assert_equal :result, result
        assert_equal [:used], pool.checkout(&:dup)
      end
    end

    def test_try_checkout_reserves_spare_capacity_and_runs_the_factory
      pool_classes.each do |klass|
        calls = Counter.new
        pool = klass.new(max_size: 1) do
          calls.increment
          []
        end

        assert_empty pool.try_checkout(&:dup)
        assert_equal 1, calls.value
        assert_equal [1, 1, 0], [pool.size, pool.available_count, pool.creating_count]
      end
    end

    def test_try_checkout_returns_nil_at_capacity_and_does_not_run_the_block
      pool_classes.each do |klass|
        pool = klass.new(max_size: 1) { Object.new }
        resource = pool.checkout
        ran = false
        result = Fiber.new do
          [pool.try_checkout, pool.try_checkout { ran = true }]
        end.resume

        assert_equal [nil, nil], result
        refute ran
        pool.checkin(resource)
      end
    end

    def test_timeout_validation_and_zero_timeout_at_capacity
      pool_classes.each do |klass|
        pool = klass.new(max_size: 1) { Object.new }

        [-1, -Float::INFINITY, Float::INFINITY, Float::NAN].each do |timeout|
          assert_raises(ArgumentError) { pool.checkout(timeout:) }
        end

        resource = pool.checkout
        error = Fiber.new { assert_raises(TimeoutError) { pool.checkout(timeout: 0) } }.resume

        assert_instance_of TimeoutError, error
        pool.checkin(resource)
      end
    end

    def test_timeout_does_not_limit_factory_duration
      pool_classes.each do |klass|
        pool = klass.new(max_size: 1) do
          sleep 0.01
          Object.new
        end

        assert_equal :acquired, pool.checkout(timeout: 0) { :acquired }
      end
    end

    def test_finite_timeout_can_bound_a_nested_checkout_at_capacity
      pool_classes.each do |klass|
        pool = klass.new(max_size: 1) { Object.new }
        resource = pool.checkout

        assert_raises(TimeoutError) { pool.checkout(timeout: 0.001) }

        pool.checkin(resource)
      end
    end

    def test_current_thread_ownership_does_not_reject_a_wait_another_thread_can_satisfy
      pool_classes.each do |klass|
        pool = klass.new(max_size: 2) { Object.new }
        first = pool.checkout
        entered = Flag.new
        release = Flag.new
        worker = Thread.new do
          second = pool.checkout
          entered.set
          Thread.pass until release.value
          pool.checkin(second)
        end
        wait_until { entered.value }
        releaser = Thread.new do
          sleep 0.01
          release.set
        end

        third = pool.checkout(timeout: 1)

        pool.checkin(third)
        pool.checkin(first)

        assert worker.join(2), "#{klass} owner did not release its resource"
        assert releaser.join(2)
      ensure
        release&.set
        worker&.kill&.join
        releaser&.kill&.join
      end
    end

    def test_waiting_checkout_acquires_after_checkin
      pool_classes.each do |klass|
        pool = klass.new(max_size: 1) { Object.new }
        resource = pool.checkout
        started = ::Queue.new
        waiter = Thread.new do
          started << true
          pool.checkout(timeout: 2) { :acquired }
        end
        started.pop
        wait_until_waiting(pool, waiter)

        refute waiter.join(0), "#{klass} waiter acquired before checkin"
        pool.checkin(resource)

        assert waiter.join(2), "#{klass} waiter did not wake after checkin"
        assert_equal :acquired, waiter.value
      ensure
        waiter&.kill&.join
        pool&.checkin(resource) if pool&.checked_out_count&.positive?
      end
    end

    def test_checkin_requires_an_explicit_checkout_owned_by_the_current_fiber
      pool_classes.each do |klass|
        pool = klass.new(max_size: 1) { Object.new }
        replacement = []

        assert_raises(OwnershipError) { pool.checkin(replacement) }
        replacement << :still_owned

        assert_equal [:still_owned], replacement
        resource = pool.checkout
        error = Fiber.new { assert_raises(OwnershipError) { pool.checkin([]) } }.resume

        assert_instance_of OwnershipError, error
        assert_equal 1, pool.checked_out_count
        pool.checkin(resource)
      end
    end

    def test_explicit_checkin_cannot_consume_a_block_checkout
      pool_classes.each do |klass|
        pool = klass.new(max_size: 1) { Object.new }

        pool.checkout do
          assert_raises(OwnershipError) { pool.checkin(Object.new) }
          assert_equal 1, pool.checked_out_count
        end

        assert_equal 1, pool.available_count
      end
    end

    def test_invalid_checkin_preserves_explicit_checkout_count
      pool_classes.each do |klass|
        pool = klass.new(max_size: 1) { Object.new }
        resource = pool.checkout

        [true, false].each do |invalid|
          assert_raises(ArgumentError) { pool.checkin(invalid) }
          assert_equal 1, pool.checked_out_count
        end

        pool.checkin(resource)

        assert_equal 0, pool.checked_out_count
        assert_equal 1, pool.available_count
      end
    end

    def test_explicit_returns_are_counted_and_allow_substitution
      pool_classes.each do |klass|
        pool = klass.new(max_size: 2) { [] }
        first = pool.checkout
        second = pool.checkout

        first << :first_original
        second << :second_original
        pool.checkin([:replacement])
        pool.checkin(nil)

        assert_equal 1, pool.size
        assert_equal 1, pool.available_count
        assert_equal 0, pool.checked_out_count
        assert_equal [:replacement], pool.checkout(&:dup)
        assert_equal [:first_original], first
        assert_equal [:second_original], second
      end
    end

    def test_nil_checkin_releases_capacity_for_later_creation
      pool_classes.each do |klass|
        calls = Counter.new
        pool = klass.new(max_size: 1) do
          calls.increment
          []
        end
        original = pool.checkout

        assert_same pool, pool.checkin(nil)
        assert_equal 0, pool.size
        assert_equal 0, pool.available_count
        assert_equal 0, pool.checked_out_count
        assert_equal 1, calls.value
        result = pool.checkout { :created }

        assert_equal :created, result
        assert_equal 2, calls.value
        assert_empty original
      end
    end

    def test_factory_failures_and_invalid_results_release_capacity
      pool_classes.each do |klass|
        calls = Counter.new
        pool = klass.new(max_size: 1) do
          case calls.increment.value
          when 1 then raise "factory failed"
          when 2 then nil
          when 3 then true
          when 4 then false
          else []
          end
        end

        assert_raises(RuntimeError) { pool.checkout }
        3.times { assert_raises(ArgumentError) { pool.checkout } }
        assert_equal [0, 0, 0], [pool.size, pool.checked_out_count, pool.creating_count]
        assert_empty pool.checkout(&:dup)
        assert_equal 5, calls.value
      end
    end

    def test_factory_failure_wakes_a_waiter_for_the_released_slot
      pool_classes.each do |klass|
        calls = Counter.new
        entered = Flag.new
        release = Flag.new
        pool = klass.new(max_size: 1) do
          attempt = calls.increment.value
          if attempt == 1
            entered.set
            Thread.pass until release.value
            raise "factory failed"
          end
          Object.new
        end
        creator = Thread.new do
          pool.checkout
        rescue RuntimeError => e
          e
        end
        wait_until { entered.value }
        waiter = Thread.new { pool.checkout(timeout: 2) { :acquired } }
        wait_until_waiting(pool, waiter)

        release.set

        assert creator.join(2), "#{klass} failing factory did not finish"
        assert_equal "factory failed", creator.value.message
        assert waiter.join(2), "#{klass} waiter did not receive the released factory slot"
        assert_equal :acquired, waiter.value
        assert_equal 2, calls.value
      ensure
        release&.set
        creator&.kill&.join
        waiter&.kill&.join
      end
    end

    def test_nil_checkin_wakes_a_waiter_for_the_released_slot
      pool_classes.each do |klass|
        calls = Counter.new
        pool = klass.new(max_size: 1) do
          calls.increment
          []
        end
        original = pool.checkout
        waiter = Thread.new { pool.checkout(timeout: 2) { :acquired } }
        wait_until_waiting(pool, waiter)

        pool.checkin(nil)

        assert waiter.join(2), "#{klass} waiter did not receive the deleted slot"
        assert_equal :acquired, waiter.value
        assert_equal 2, calls.value
        assert_empty original
      ensure
        waiter&.kill&.join
        pool&.checkin(original) if pool&.checked_out_count&.positive?
      end
    end

    def test_nonlocal_factory_exit_releases_capacity
      pool_classes.each do |klass|
        calls = Counter.new
        pool = klass.new(max_size: 1) do
          throw :factory_exit, :exited if calls.increment.value == 1
          Object.new
        end

        result = catch(:factory_exit) do
          pool.checkout
          :not_exited
        end

        assert_equal :exited, result
        assert_equal [0, 0, 0], [pool.size, pool.checked_out_count, pool.creating_count]
        acquired = pool.checkout { :acquired }

        assert_equal :acquired, acquired
        assert_equal 2, calls.value
      end
    end

    def test_factory_cancellation_releases_reserved_capacity
      pool_classes.each do |klass|
        entered = Flag.new
        pool = klass.new(max_size: 1) do
          entered.set
          loop { Thread.pass }
        end
        cancellation = RuntimeError.new("cancel factory")
        worker = Thread.new do
          pool.checkout
        rescue RuntimeError => e
          e
        end
        wait_until { entered.value }

        worker.raise(cancellation)

        assert worker.join(2), "#{klass} canceled factory did not finish"
        assert_same cancellation, worker.value
        assert_equal [0, 0, 0], [pool.size, pool.checked_out_count, pool.creating_count]
      ensure
        worker&.kill&.join
      end
    end

    def test_block_cancellation_checks_the_resource_in
      pool_classes.each do |klass|
        entered = Flag.new
        pool = klass.new(max_size: 1) { [] }
        cancellation = RuntimeError.new("cancel checkout block")
        worker = Thread.new do
          pool.checkout do |resource|
            resource << :entered
            entered.set
            loop { Thread.pass }
          end
        rescue RuntimeError => e
          e
        end
        wait_until { entered.value }

        worker.raise(cancellation)

        assert worker.join(2), "#{klass} canceled checkout block did not finish"
        assert_same cancellation, worker.value
        assert_equal [:entered], pool.checkout(&:dup)
        assert_equal [1, 1, 0], [pool.size, pool.available_count, pool.checked_out_count]
      ensure
        worker&.kill&.join
      end
    end

    def test_concurrent_creation_reserves_no_more_than_max_size
      pool_classes.each do |klass|
        calls = Counter.new
        release = Flag.new
        pool = klass.new(max_size: 2) do
          calls.increment
          Thread.pass until release.value
          [Object.new.freeze]
        end
        workers = 4.times.map do
          Thread.new { pool.checkout(timeout: 2) { it.fetch(0) } }
        end
        wait_until { calls.value == 2 }
        100.times { Thread.pass }

        assert_equal 2, calls.value
        assert_equal 2, pool.creating_count
        assert_equal 0, pool.available_count
        release.set
        tokens = workers.map do |worker|
          assert worker.join(3), "#{klass} pool worker did not finish"
          worker.value
        end

        assert_equal 2, tokens.uniq.length
        assert_equal 2, pool.size
        assert_equal 2, pool.available_count
        assert_equal 0, pool.creating_count
      ensure
        release&.set
        workers&.each { it.kill.join }
      end
    end

    def test_concurrent_creation_in_distinct_top_level_pools_keeps_resources_separate
      klass = concrete_pool_class(Farce)
      10.times do
        release = Flag.new
        pools = 2.times.map do |pool_index|
          klass.new(max_size: 4) do
            Thread.pass until release.value
            [pool_index, Object.new.freeze]
          end
        end
        workers = pools.each_with_index.flat_map do |pool, _pool_index|
          4.times.map do
            Thread.new { pool.checkout(timeout: 2) { it.fetch(0) } }
          end
        end
        wait_until { pools.sum(&:creating_count) == 8 }
        release.set
        results = workers.map do |worker|
          assert worker.join(3), "top-level pool worker did not finish"
          worker.value
        end

        assert_equal [0, 0, 0, 0, 1, 1, 1, 1], results
        assert_equal [4, 4], pools.map(&:available_count)
      ensure
        release&.set
        workers&.each { it.kill.join }
      end
    end

    def test_waiting_checkout_allows_scheduled_fibers_to_progress
      return unless Fiber.respond_to?(:set_scheduler)

      pool_classes.each do |klass|
        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        pool = klass.new(max_size: 1) { Object.new }
        events = []
        Fiber.schedule do
          pool.checkout do
            events << :holding
            Fiber.scheduler.kernel_sleep(0.01)
            events << :releasing
          end
        end
        Fiber.schedule do
          events << :waiting
          pool.checkout(timeout: 1) { events << :acquired }
        end
        Fiber.set_scheduler(nil)

        assert_equal %i[holding waiting releasing acquired], events
        assert_operator scheduler.io_wait_calls + scheduler.block_calls, :>=, 1
      ensure
        Fiber.set_scheduler(nil) if Fiber.scheduler
      end
    end

    def test_bare_basic_object_is_a_valid_resource
      pool_classes.each do |klass|
        pool = klass.new(max_size: 1) { BasicObject.new }
        result = pool.checkout { :used }

        assert_equal :used, result
        assert_equal 1, pool.available_count
      end
    end

    def test_top_level_pool_is_shareable
      klass = concrete_pool_class(Farce)
      pool = klass.new(max_size: 1) { [] }

      assert_predicate pool, :frozen?
      assert_predicate pool, :ractor_shareable?
      assert Ractor.shareable?(pool)
    end

    def test_local_pool_is_shareable
      klass = concrete_pool_class(Local)
      pool = klass.new(max_size: 1) { [] }

      assert_predicate pool, :frozen?
      assert_predicate pool, :ractor_shareable?
      assert Ractor.shareable?(pool)
    end

    def test_unshared_pool_is_unshareable
      klass = concrete_pool_class(Unshared)
      pool = klass.new(max_size: 1) { [] }

      refute_predicate pool, :ractor_shareable?
      refute Ractor.shareable?(pool)
      assert_raises(NoMethodError) { pool.freeze }
    end

    def test_top_level_pool_transfers_a_resource_across_ractors
      klass = concrete_pool_class(Farce)
      pool = klass.new(max_size: 1) { [] }
      worker = Ractor.new(pool) do |shared|
        shared.checkout do |resource|
          resource << :worker
          :done
        end
      end

      assert_equal :done, ractor_value(worker)
      assert_equal [:worker], pool.checkout(&:dup)
    end

    def test_top_level_checkin_moves_a_replacement_and_leaves_the_original_with_the_caller
      return unless Internal.native_ractors?

      klass = concrete_pool_class(Farce)
      pool = klass.new(max_size: 1) { [] }
      original = pool.checkout
      replacement = [:replacement]

      pool.checkin(replacement)

      assert_raises(Ractor::MovedError) { replacement.length }
      original << :caller_owned

      assert_equal [:caller_owned], original
      assert_equal [:replacement], pool.checkout(&:dup)
    end

    def test_unshared_pool_passes_resource_references_directly
      klass = concrete_pool_class(Unshared)
      resource = []
      pool = klass.new(max_size: 1) { resource }

      assert_same resource, pool.checkout(&:itself)
      assert_same resource, pool.checkout
      pool.checkin(resource)

      assert_same resource, pool.checkout(&:itself)
    end

    def test_local_pool_has_independent_capacity_and_resources_per_fiber_scope
      klass = concrete_pool_class(Local)
      calls = Counter.new
      pool = klass.new(scope: :fiber, max_size: 1) do
        calls.increment
        []
      end
      pool.checkout { it << :parent }
      child = Fiber.new do
        pool.checkout { |resource| [resource.dup, resource.object_id, pool.size] }
      end.resume
      parent = pool.checkout { |resource| [resource.dup, resource.object_id, pool.size] }

      assert_equal [[], %i[parent]], [child.fetch(0), parent.fetch(0)]
      refute_equal child.fetch(1), parent.fetch(1)
      assert_equal [1, 1], [child.fetch(2), parent.fetch(2)]
      assert_equal 2, calls.value
    end

    def test_local_pool_supports_all_scopes
      klass = concrete_pool_class(Local)
      %i[ractor thread_group thread fiber_storage fiber].each do |scope|
        pool = klass.new(scope:, max_size: 1) { Object.new }

        assert_equal scope, pool.scope
        assert_equal 1, pool.max_size
      end

      assert_raises(ArgumentError) do
        klass.new(scope: :invalid, max_size: 1) { Object.new }
      end
    end

    private

    def pool_classes = POOL_CLASSES

    def concrete_pool_class(namespace)
      namespace.const_get(:LeasePool, false)
    end

    def return_from_checkout(pool)
      pool.checkout do |resource|
        resource << :returned
        return :returned
      end

      flunk "checkout ignored a nonlocal return"
    end

    def wait_until
      deadline = Clock.timeout(2)
      Thread.pass until yield || Clock.now >= deadline

      assert yield, "condition did not become true before timeout"
    end

    def wait_until_waiting(pool, thread)
      internal = pool.send(:internal_pool)
      signal   = internal.instance_variable_get(:@signal)
      wait_until { signal.num_waiting.positive? || thread.status == "sleep" }
    end
  end
end
