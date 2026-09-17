# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestLease < Test
    include Helpers::InternalTestHelpers

    LEASE_CLASSES = [Lease, Unshared::Lease, Local::Lease].freeze
    DIRECT_CLASSES = [Lease, Unshared::Lease].freeze

    def run(...) = Timeout.timeout(10) { super }

    def teardown
      Fiber.set_scheduler(nil) if Fiber.respond_to?(:scheduler) && Fiber.scheduler
    end

    def test_public_hierarchy
      assert_equal Abstract::Lease, Lease.superclass
      assert_equal Abstract::Lease, Unshared::Lease.superclass
      assert_equal Abstract::Lease, Local::Lease.superclass
    end

    def test_constructors_require_only_a_block
      LEASE_CLASSES.each do |klass|
        assert_raises(ArgumentError) { klass.new }
        assert_raises(ArgumentError) { klass.new(:resource) { :resource } }
      end
    end

    def test_direct_constructors_initialize_once_in_the_constructing_fiber
      DIRECT_CLASSES.each do |klass|
        calls = Counter.new
        constructing_fiber = Fiber.current.object_id
        lease = klass.new do
          calls.increment
          [Fiber.current.object_id]
        end

        result = lease.checkout { it.fetch(0) }

        assert_equal 1, calls.value
        assert_equal constructing_fiber, result
        assert_equal 1, calls.value
      end
    end

    def test_constructors_reject_nil_and_boolean_resources
      LEASE_CLASSES.each do |klass|
        [nil, true, false].each do |invalid|
          if klass == Local::Lease
            lease = klass.new { invalid }

            assert_raises(ArgumentError) { lease.checkout }
          else
            assert_raises(ArgumentError) { klass.new { invalid } }
          end
        end
      end
    end

    def test_resource_validation_accepts_a_bare_basic_object
      LEASE_CLASSES.each do |klass|
        lease = klass.new { BasicObject.new }
        result = lease.checkout { :used }

        assert_equal :used, result
        assert_predicate lease, :available?
      end
    end

    def test_block_checkout_returns_results_and_restores_availability
      LEASE_CLASSES.each do |klass|
        lease = klass.new { [:initial] }

        assert_predicate lease, :available?
        refute_predicate lease, :checked_out?
        refute_predicate lease, :owned?
        result = lease.checkout do |resource|
          assert_equal [:initial], resource
          refute_predicate lease, :available?
          assert_predicate lease, :checked_out?
          assert_predicate lease, :owned?
          resource << :changed
          :result
        end

        assert_equal :result, result
        assert_predicate lease, :available?
        refute_predicate lease, :checked_out?
        refute_predicate lease, :owned?
        assert_equal %i[initial changed], lease.checkout(&:dup)
      end
    end

    def test_block_checkout_can_return_false_or_nil
      LEASE_CLASSES.each do |klass|
        lease = klass.new { Object.new }

        false_result = lease.checkout { false }
        nil_result = lease.checkout { nil }
        false_try_result = lease.try_checkout { false }
        nil_try_result = lease.try_checkout { nil }

        refute false_result
        assert_nil nil_result
        refute false_try_result
        assert_nil nil_try_result
        assert_predicate lease, :available?
      end
    end

    def test_block_checkout_checks_in_when_the_block_raises
      LEASE_CLASSES.each do |klass|
        lease = klass.new { [:initial] }
        failure = RuntimeError.new("failed use")
        raised = assert_raises(RuntimeError) do
          lease.checkout do |resource|
            resource << :changed
            raise failure
          end
        end

        assert_same failure, raised
        assert_equal %i[initial changed], lease.checkout(&:dup)
      end
    end

    def test_block_checkout_checks_in_after_a_nonlocal_return
      LEASE_CLASSES.each do |klass|
        lease = klass.new { [:initial] }

        assert_equal :returned, return_from_checkout(lease)
        assert_equal %i[initial changed], lease.checkout(&:dup)
      end
    end

    def test_async_interruption_at_block_handoff_does_not_strand_the_lease
      return unless RUBY_ENGINE == "ruby"

      LEASE_CLASSES.each do |klass|
        %i[checkout try_checkout].each do |operation|
          assert_async_block_handoff_cleanup(klass, operation)
        end
      end
    end

    def test_explicit_checkout_checkin_and_replacement
      LEASE_CLASSES.each do |klass|
        lease = klass.new { [:initial] }
        original = lease.checkout

        assert_equal [:initial], original
        assert_predicate lease, :owned?
        replacement = [:replacement]

        assert_same lease, lease.checkin(replacement)
        assert_equal [:replacement], lease.checkout(&:dup)
        assert_equal [:initial], original
      end
    end

    def test_try_checkout_is_immediate_when_another_fiber_owns_the_resource
      LEASE_CLASSES.each do |klass|
        lease = klass.new { Object.new }
        resource = lease.checkout
        ran = false

        result = Fiber.new do
          [lease.try_checkout, lease.try_checkout { ran = true }]
        end.resume

        assert_equal [nil, nil], result
        refute ran
        lease.checkin(resource)
      end
    end

    def test_recursive_checkout_raises_thread_error
      LEASE_CLASSES.each do |klass|
        lease = klass.new { Object.new }

        lease.checkout do
          assert_raises(ThreadError) { lease.checkout(timeout: 0) }
          assert_raises(ThreadError) { lease.try_checkout }
        end
      end
    end

    def test_checkin_requires_the_owning_fiber
      LEASE_CLASSES.each do |klass|
        lease = klass.new { Object.new }
        resource = lease.checkout
        replacement = []
        error = Fiber.new { assert_raises(OwnershipError) { lease.checkin(replacement) } }.resume

        assert_instance_of OwnershipError, error
        replacement << :still_owned

        assert_equal [:still_owned], replacement
        assert_predicate lease, :owned?
        lease.checkin(resource)
      end
    end

    def test_checkin_without_a_checkout_raises_ownership_error
      LEASE_CLASSES.each do |klass|
        lease = klass.new { Object.new }
        replacement = []

        assert_raises(OwnershipError) { lease.checkin(replacement) }
        replacement << :still_owned

        assert_equal [:still_owned], replacement
        assert_predicate lease, :available?
      end
    end

    def test_invalid_checkin_preserves_the_checkout_for_recovery
      LEASE_CLASSES.each do |klass|
        lease = klass.new { Object.new }
        resource = lease.checkout

        [nil, true, false].each do |invalid|
          assert_raises(ArgumentError) { lease.checkin(invalid) }
          assert_predicate lease, :owned?
          assert_predicate lease, :checked_out?
        end

        assert_same lease, lease.checkin(resource)
        assert_predicate lease, :available?
      end
    end

    def test_timeout_validation_and_zero_timeout
      LEASE_CLASSES.each do |klass|
        lease = klass.new { Object.new }

        [-1, -Float::INFINITY, Float::INFINITY, Float::NAN].each do |timeout|
          assert_raises(ArgumentError) { lease.checkout(timeout:) }
        end

        resource = lease.checkout(timeout: 0)
        error = Fiber.new { assert_raises(TimeoutError) { lease.checkout(timeout: 0) } }.resume

        assert_instance_of TimeoutError, error
        lease.checkin(resource)
      end
    end

    def test_waiting_checkout_acquires_after_checkin
      LEASE_CLASSES.each do |klass|
        lease = klass.new { [:initial] }
        resource = lease.checkout
        started = ::Queue.new
        waiter = Thread.new do
          started << true
          lease.checkout(timeout: 2) { |value| value + [:waiter] }
        end
        started.pop
        wait_until_waiters(lease, 1)

        refute waiter.join(0), "#{klass} waiter acquired before checkin"

        lease.checkin(resource)

        assert waiter.join(2), "#{klass} waiter did not wake after checkin"
        assert_equal %i[initial waiter], waiter.value
      ensure
        waiter&.kill&.join
        lease&.checkin(resource) if lease&.owned?
      end
    end

    def test_canceling_one_waiter_does_not_strand_another
      LEASE_CLASSES.each do |klass|
        lease = klass.new { Object.new }
        resource = lease.checkout
        ready = ::Queue.new
        interrupted = Thread.new do
          ready << true
          lease.checkout(timeout: 5)
        rescue RuntimeError => e
          e
        end
        remaining = Thread.new do
          ready << true
          lease.checkout(timeout: 5) { :acquired }
        end
        2.times { ready.pop }
        wait_until_waiters(lease, 2)

        interrupted.raise "cancel checkout"

        assert interrupted.join(2), "#{klass} canceled waiter did not unwind"
        assert_equal "cancel checkout", interrupted.value.message
        lease.checkin(resource)

        assert remaining.join(2), "#{klass} remaining waiter was stranded"
        assert_equal :acquired, remaining.value
      ensure
        interrupted&.kill&.join
        remaining&.kill&.join
        lease&.checkin(resource) if lease&.owned?
      end
    end

    def test_waiting_checkout_allows_scheduled_fibers_to_progress
      return unless Fiber.respond_to?(:set_scheduler)

      LEASE_CLASSES.each do |klass|
        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        lease = klass.new { Object.new }
        events = []
        holding = Farce::Signal.new
        release = Farce::Signal.new
        Fiber.schedule do
          lease.checkout do
            events << :holding
            holding.broadcast
            release.wait(0)
            events << :releasing
          end
        end
        Fiber.schedule do
          holding.wait(0)
          events << :waiting
          release.broadcast
          lease.checkout(timeout: 1) { events << :acquired }
        end
        Fiber.set_scheduler(nil)

        assert_equal %i[holding waiting releasing acquired], events
        assert_operator scheduler.io_wait_calls + scheduler.block_calls, :>=, 1
      ensure
        Fiber.set_scheduler(nil) if Fiber.scheduler
      end
    end

    def test_retire_requires_ownership
      LEASE_CLASSES.each do |klass|
        lease = klass.new { Object.new }

        assert_raises(OwnershipError) { lease.retire }
        assert_predicate lease, :available?
      end
    end

    def test_retirement_inside_block_is_permanent_and_skips_cleanup
      LEASE_CLASSES.each do |klass|
        lease = klass.new { [:initial] }
        retired_resource = nil

        result = lease.checkout do |resource|
          retired_resource = resource
          resource << :retired

          assert_same lease, lease.retire
          :result
        end

        assert_equal :result, result
        assert_equal %i[initial retired], retired_resource
        assert_predicate lease, :retired?
        refute_predicate lease, :available?
        refute_predicate lease, :checked_out?
        refute_predicate lease, :owned?
        assert_raises(RetiredLeaseError) { lease.checkout }
        assert_raises(RetiredLeaseError) { lease.try_checkout }
        replacement = []
        assert_raises(RetiredLeaseError) { lease.checkin(replacement) }
        replacement << :still_owned

        assert_equal [:still_owned], replacement
        assert_same lease, lease.retire
      end
    end

    def test_retirement_does_not_mask_a_block_exception
      LEASE_CLASSES.each do |klass|
        lease = klass.new { Object.new }
        failure = RuntimeError.new("failed after retirement")
        raised = assert_raises(RuntimeError) do
          lease.checkout do
            lease.retire
            raise failure
          end
        end

        assert_same failure, raised
        assert_predicate lease, :retired?
      end
    end

    def test_retirement_wakes_waiters
      LEASE_CLASSES.each do |klass|
        lease = klass.new { Object.new }
        lease.checkout
        started = ::Queue.new
        waiter = Thread.new do
          started << true
          lease.checkout(timeout: 5)
        rescue StandardError => e
          e
        end
        started.pop
        wait_until_waiters(lease, 1)

        lease.retire

        assert waiter.join(2), "#{klass} waiter did not wake after retirement"
        assert_instance_of RetiredLeaseError, waiter.value
      ensure
        waiter&.kill&.join
      end
    end

    def test_top_level_and_local_leases_are_shareable
      [Lease, Local::Lease].each do |klass|
        lease = klass.new { [] }

        assert_predicate lease, :frozen?
        assert_predicate lease, :ractor_shareable?
        assert Ractor.shareable?(lease)
      end

      lease = Unshared::Lease.new { [] }

      refute_predicate lease, :ractor_shareable?
      refute Ractor.shareable?(lease)
      assert_raises(NoMethodError) { lease.freeze }
    end

    def test_top_level_lease_transfers_repeatedly_across_ractors
      lease = Lease.new { [:initial] }
      worker = Ractor.new(lease) do |shared|
        shared.checkout do |resource|
          resource << :worker
          resource.length
        end
      end

      assert_equal 2, ractor_value(worker)
      assert_equal %i[initial worker], lease.checkout(&:dup)
    end

    def test_top_level_checkin_moves_the_replacement_but_keeps_the_original_with_the_caller
      return unless Internal.native_ractors?

      lease = Lease.new { [:initial] }
      original = lease.checkout
      replacement = [:replacement]

      lease.checkin(replacement)

      assert_raises(Ractor::MovedError) { replacement.length }
      original << :caller_owned

      assert_equal %i[initial caller_owned], original
      assert_equal [:replacement], lease.checkout(&:dup)
    end

    def test_failed_top_level_checkin_transfer_preserves_ownership
      return unless Internal.native_ractors?

      lease = Lease.new { Object.new }
      original = lease.checkout
      unmovable = Internal::Unshareable.prevent_movable(Object.new)

      assert_raises(Ractor::Error, TypeError) { lease.checkin(unmovable) }
      assert_predicate lease, :owned?
      assert_same lease, lease.checkin(original)
      assert_predicate lease, :available?
    end

    def test_unshared_lease_passes_the_same_reference
      resource = []
      lease = Unshared::Lease.new { resource }

      assert_same resource, lease.checkout(&:itself)
      checked_out = lease.checkout
      lease.checkin(checked_out)

      assert_same resource, lease.checkout(&:itself)
    end

    def test_local_lease_initializes_once_for_concurrent_callers_in_a_shared_scope
      calls = Counter.new
      lease = Local::Lease.new do
        calls.increment
        Thread.pass
        []
      end
      workers = 8.times.map do
        Thread.new { lease.checkout(timeout: 2, &:object_id) }
      end
      object_ids = workers.map do |worker|
        assert worker.join(3), "local lease worker did not finish"
        worker.value
      end

      assert_equal 1, calls.value
      assert_equal 1, object_ids.uniq.length
    ensure
      workers&.each { it.kill.join }
    end

    def test_local_lease_coordinates_yielding_initialization_between_scheduled_fibers
      return unless Fiber.respond_to?(:set_scheduler)

      scheduler = Helpers::QueueTestScheduler.new
      Fiber.set_scheduler(scheduler)
      calls = Counter.new
      lease = Local::Lease.new do
        Fiber.scheduler.kernel_sleep(0.01)
        calls.increment
        []
      end
      object_ids = []
      2.times do
        Fiber.schedule { object_ids << lease.checkout(&:object_id) }
      end
      Fiber.set_scheduler(nil)

      assert_equal 1, calls.value
      assert_equal 2, object_ids.length
      assert_equal 1, object_ids.uniq.length
    ensure
      Fiber.set_scheduler(nil) if Fiber.respond_to?(:scheduler) && Fiber.scheduler
    end

    def test_local_lease_retries_after_initializer_failure
      calls = Counter.new
      lease = Local::Lease.new do
        raise "not ready" if calls.increment == 1
        []
      end

      assert_raises(RuntimeError) { lease.checkout }
      assert_empty lease.checkout(&:itself)
      assert_equal 2, calls.value
    end

    def test_local_lease_retries_after_nonlocal_initializer_exit
      calls = Counter.new
      lease = Local::Lease.new do
        throw :initializer_exit, :exited if calls.increment.value == 1
        []
      end

      result = catch(:initializer_exit) do
        lease.checkout
        :not_exited
      end

      assert_equal :exited, result
      assert_empty lease.checkout(&:dup)
      assert_equal 2, calls.value
    end

    def test_local_try_and_timeout_observe_initialization_in_progress
      calls = Counter.new
      entered = Flag.new
      release = Flag.new
      lease = Local::Lease.new do
        calls.increment
        entered.set
        Thread.pass until release.value
        []
      end
      initializer = Thread.new { lease.checkout { :initialized } }
      wait_until { entered.value }

      assert_nil Timeout.timeout(1) { lease.try_checkout }
      assert_raises(TimeoutError) { lease.checkout(timeout: 0.02) }
      release.set

      assert initializer.join(2), "local lease initializer did not finish"
      assert_equal :initialized, initializer.value
      assert_equal 1, calls.value
      assert_empty lease.checkout(&:dup)
    ensure
      release&.set
      initializer&.kill&.join
    end

    def test_local_checkout_timeout_does_not_limit_initializer_runtime
      lease = Local::Lease.new do
        sleep 0.02
        Object.new
      end

      assert_equal :acquired, lease.checkout(timeout: 0) { :acquired }
    end

    def test_interrupting_local_initializer_releases_the_reservation
      calls = Counter.new
      entered = Farce::Queue.new
      release = Farce::Queue.new
      lease = Local::Lease.new do
        attempt = calls.increment.value
        if attempt == 1
          entered << true
          release.pop
        end
        []
      end
      initializer = Thread.new do
        lease.checkout
      rescue RuntimeError => e
        e
      end
      entered.pop
      waiter = Thread.new { lease.checkout(timeout: 2) { :acquired } }
      wait_until_initialization_waiters(lease, 1)

      initializer.raise "cancel initializer"

      assert initializer.join(2), "canceled local initializer did not unwind"
      assert_equal "cancel initializer", initializer.value.message
      assert waiter.join(2), "initializer waiter did not retry after cancellation"
      assert_equal :acquired, waiter.value
      assert_equal 2, calls.value
    ensure
      release << true if release
      initializer&.kill&.join
      waiter&.kill&.join
    end

    def test_local_lease_supports_all_scopes
      %i[ractor thread_group thread fiber_storage fiber].each do |scope|
        lease = Local::Lease.new(scope:) { [] }

        assert_equal scope, lease.scope
      end

      assert_raises(ArgumentError) { Local::Lease.new(scope: :invalid) { [] } }
    end

    def test_local_fiber_scope_has_independent_resources_and_lifecycle
      calls = Counter.new
      lease = Local::Lease.new(scope: :fiber) do
        calls.increment
        []
      end

      lease.checkout { it << :parent }
      child = Fiber.new do
        lease.checkout { |resource| [resource.dup, resource.object_id] }
      end.resume
      parent = lease.checkout { |resource| [resource.dup, resource.object_id] }

      assert_equal [[], %i[parent]], [child.first, parent.first]
      refute_equal child.last, parent.last
      assert_equal 2, calls.value

      lease.checkout { lease.retire }
      assert_raises(RetiredLeaseError) { lease.checkout }
      assert_empty Fiber.new { lease.checkout(&:itself) }.resume
      assert_equal 3, calls.value
      assert_raises(RetiredLeaseError) { lease.checkout }
    end

    def test_local_thread_scope_shares_a_resource_but_keeps_fiber_ownership
      lease = Local::Lease.new(scope: :thread) { [] }
      holder = Fiber.new do
        resource = lease.checkout
        Fiber.yield resource.object_id
        lease.checkin(resource)
      end
      object_id = holder.resume

      observation = Fiber.new do
        [lease.owned?, lease.try_checkout]
      end.resume

      assert_equal [false, nil], observation
      holder.resume

      assert_equal object_id, Fiber.new { lease.checkout(&:object_id) }.resume
      refute_equal object_id, Thread.new { lease.checkout(&:object_id) }.value
    end

    def test_local_block_cleanup_uses_the_scope_resolved_at_checkout
      group = ThreadGroup.new
      lease = Local::Lease.new(scope: :thread_group) { [] }
      worker = Thread.new do
        lease.checkout do |resource|
          resource << :changed
          group.add(Thread.current)
          :done
        end
      end

      assert_equal :done, worker.value
      assert_equal [:changed], lease.checkout(&:dup)
    ensure
      worker&.kill&.join
    end

    def test_local_default_scope_is_independent_between_ractors
      calls = Counter.new
      lease = Local::Lease.new do
        calls.increment
        []
      end
      lease.checkout { it << :parent }
      worker = Ractor.new(lease) do |local|
        local.checkout do |resource|
          before = resource.dup
          resource << :worker
          before
        end
      end

      assert_empty ractor_value(worker)
      assert_equal [:parent], lease.checkout(&:itself)
      assert_equal 2, calls.value
    end

    private

    def assert_async_block_handoff_cleanup(klass, operation)
      marker = Object.new.freeze
      lease = klass.new { [marker] }
      backend = lease.send(:internal_lease)
      injection = ::Queue.new
      acknowledgment = ::Queue.new
      failure = Class.new(RuntimeError)
      worker = nil
      injected = false
      trace = TracePoint.new(:line) do |event|
        next unless Thread.current.equal?(worker)
        next unless event.self.equal?(backend) && event.method_id == :try_acquire_block
        next if injected
        next unless event.binding.local_variable_defined?(:resource)
        next unless event.binding.local_variable_get(:resource)

        injected = true
        trace.disable
        injection << Thread.current
        acknowledgment.pop
      end
      worker = Thread.new do
        trace.enable do
          lease.public_send(operation) { :done }
        end
      rescue failure => e
        e
      end
      target = Timeout.timeout(2) { injection.pop }

      refute_predicate lease, :available?
      assert_predicate lease, :checked_out?
      target.raise failure, "async at #{operation} block handoff"
      acknowledgment << true

      assert worker.join(2), "#{klass} #{operation} handoff did not unwind"
      assert_instance_of failure, worker.value
      assert_equal "async at #{operation} block handoff", worker.value.message
      assert_predicate lease, :available?
      refute_predicate lease, :checked_out?
      refute_predicate lease, :owned?
      recovered_marker = lease.checkout { it.fetch(0) }

      assert_same marker, recovered_marker
    ensure
      trace&.disable
      acknowledgment << true if acknowledgment
      worker&.kill
      worker&.join(2)
    end

    def return_from_checkout(lease)
      lease.checkout do |resource|
        resource << :changed
        return :returned
      end

      flunk "checkout ignored a nonlocal return"
    end

    def wait_until_waiters(lease, count)
      backend = lease.send(:internal_lease)
      signal = backend.instance_variable_get(:@signal)
      deadline = Clock.timeout(1)
      Thread.pass until signal.num_waiting >= count || Clock.now >= deadline

      assert_operator signal.num_waiting, :>=, count, "lease did not register #{count} waiter(s)"
    end

    def wait_until_initialization_waiters(lease, count)
      reservation = lease.send(:scoped_value)
      signal = reservation.instance_variable_get(:@signal)
      deadline = Clock.timeout(1)
      Thread.pass until signal.num_waiting >= count || Clock.now >= deadline

      assert_operator signal.num_waiting, :>=, count, "initializer did not register #{count} waiter(s)"
    end

    def wait_until
      deadline = Clock.timeout(2)
      Thread.pass until yield || Clock.now >= deadline

      assert yield, "condition did not become true before timeout"
    end
  end
end
