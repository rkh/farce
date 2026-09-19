# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestLeaseMap < Test
    include Helpers::InternalTestHelpers

    MAP_CLASSES = [Farce::LeaseMap, Unshared::LeaseMap, Local::LeaseMap].freeze

    def run(...) = Timeout.timeout(10) { super }

    def test_public_hierarchy
      map_classes.each { assert_equal Abstract::LeaseMap, it.superclass }

      assert_operator Abstract::LeaseMap, :<, Abstract::Map
      refute_operator Abstract::LeaseMap, :<, Abstract::Lease
    end

    def test_constructor_requires_only_an_entry_building_block
      map_classes.each do |klass|
        assert_raises(ArgumentError) { klass.new }
        assert_raises(ArgumentError) { klass.new({}) { {} } }
        if klass.name == "Farce::Local::LeaseMap"
          map = klass.new { Object.new }

          assert_raises(TypeError, ArgumentError) { map.size }
        else
          assert_raises(TypeError, ArgumentError) { klass.new { Object.new } }
        end
      end
    end

    def test_direct_initializers_run_once_in_the_constructing_fiber
      direct_map_classes.each do |klass|
        calls = Counter.new
        constructing_fiber = Fiber.current.object_id
        map = klass.new do
          calls.increment
          { key: [Fiber.current.object_id] }
        end

        assert_equal 1, calls.value
        assert_equal constructing_fiber, map.checkout(:key) { it.fetch(0) }
        assert_equal 1, calls.value
      end
    end

    def test_empty_initializer_is_valid_and_never_becomes_a_per_key_factory
      map_classes.each do |klass|
        calls = Counter.new
        map = klass.new do
          calls.increment
          {}
        end

        assert_empty map
        assert_raises(KeyError) { map.checkout(:missing) }
        assert_raises(KeyError) { map.try_checkout(:missing) }
        assert_equal 1, calls.value
      end
    end

    def test_initializer_rejects_nil_and_boolean_values
      map_classes.each do |klass|
        [nil, true, false].each do |invalid|
          if klass.name == "Farce::Local::LeaseMap"
            map = klass.new { { key: invalid } }
            assert_raises(ArgumentError) { map.size }
          else
            assert_raises(ArgumentError) { klass.new { { key: invalid } } }
          end
        end
      end
    end

    def test_bare_basic_object_is_a_valid_value
      map_classes.each do |klass|
        map = klass.new { { key: BasicObject.new } }
        result = map.checkout(:key) { :used }

        assert_equal :used, result
        assert map.available?(:key)
      end
    end

    def test_checkout_state_and_block_result
      map_classes.each do |klass|
        map = klass.new { { key: [:initial] } }

        assert map.available?(:key)
        refute map.checked_out?(:key)
        refute map.owned?(:key)
        result = map.checkout(:key) do |resource|
          assert_equal [:initial], resource
          refute map.available?(:key)
          assert map.checked_out?(:key)
          assert map.owned?(:key)
          resource << :changed
          :result
        end

        assert_equal :result, result
        assert map.available?(:key)
        assert_equal %i[initial changed], map.checkout(:key, &:dup)
      end
    end

    def test_block_checkout_returns_nil_or_false_and_checks_in
      map_classes.each do |klass|
        map = klass.new { { key: Object.new } }

        assert_nil map.checkout(:key) { nil }
        refute map.checkout(:key) { false }
        assert_nil map.try_checkout(:key) { nil }
        refute map.try_checkout(:key) { false }
        assert map.available?(:key)
      end
    end

    def test_block_checkout_checks_in_after_exception_and_nonlocal_return
      map_classes.each do |klass|
        map = klass.new { { key: [] } }
        failure = RuntimeError.new("failed use")
        raised = assert_raises(RuntimeError) do
          map.checkout(:key) do |resource|
            resource << :exception
            raise failure
          end
        end

        assert_same failure, raised
        assert_equal :returned, return_from_checkout(map)
        assert_equal %i[exception returned], map.checkout(:key, &:dup)
      end
    end

    def test_user_retired_lease_errors_are_not_converted_to_key_errors
      map_classes.each do |klass|
        map = klass.new { { key: Object.new } }
        failure = RetiredLeaseError.new("user failure")

        assert_same failure, assert_raises(RetiredLeaseError) { map.checkout(:key) { raise failure } }
        raised = assert_raises(RetiredLeaseError) do
          map.each_pair { raise failure } # rubocop:disable Lint/UnreachableLoop
        end

        assert_same failure, raised
        assert map.available?(:key)
      end
    end

    def test_explicit_checkout_checkin_and_replacement
      map_classes.each do |klass|
        map = klass.new { { key: [:initial] } }
        original = map.checkout(:key)

        assert_same map, map.checkin(:key, [:replacement])
        assert_equal [:replacement], map.checkout(:key, &:dup)
        assert_equal [:initial], original
      end
    end

    def test_direct_handle_replacement_is_visible_to_map_reads
      map_classes.each do |klass|
        map = klass.new { { key: [:initial] } }
        handle = map.lease_for(:key)
        original = handle.checkout

        map[:key] = [:replacement]

        assert_equal [:replacement], map[:key]
        assert_raises(ArgumentError) { map[:key] = true }
        assert_equal [:replacement], map[:key]
        handle.checkin(map[:key])

        assert_equal [:initial], original
        assert_equal [:replacement], map.checkout(:key, &:dup)
      end
    end

    def test_checkout_unknown_key_preserves_hash_like_error
      map_classes.each do |klass|
        map = klass.new { {} }

        assert_raises(KeyError) { map.checkout(:missing) }
        assert_raises(KeyError) { map.try_checkout(:missing) }
      end
    end

    def test_try_checkout_is_immediate_for_a_busy_key
      map_classes.each do |klass|
        map = klass.new { { key: Object.new } }
        resource = map.checkout(:key)
        ran = false
        result = Fiber.new do
          [map.try_checkout(:key), map.try_checkout(:key) { ran = true }]
        end.resume

        assert_equal [nil, nil], result
        refute ran
        map.checkin(:key, resource)
      end
    end

    def test_different_keys_can_be_checked_out_by_one_fiber
      map_classes.each do |klass|
        map = klass.new { { first: [], second: [] } }
        first = map.checkout(:first)
        second = map.checkout(:second)

        assert map.owned?(:first)
        assert map.owned?(:second)
        assert_raises(ThreadError) { map.checkout(:first, timeout: 0) }
        assert_raises(ThreadError) { map.try_checkout(:second) }
        map.checkin(:first, first)
        map.checkin(:second, second)
      end
    end

    def test_checkin_requires_the_key_checkout_owner
      map_classes.each do |klass|
        map = klass.new { { key: Object.new } }
        resource = map.checkout(:key)
        replacement = []
        error = Fiber.new do
          assert_raises(OwnershipError) { map.checkin(:key, replacement) }
        end.resume

        assert_instance_of OwnershipError, error
        replacement << :still_owned

        assert_equal [:still_owned], replacement
        assert map.owned?(:key)
        map.checkin(:key, resource)
        assert_raises(OwnershipError) { map.checkin(:key, Object.new) }
      end
    end

    def test_invalid_checkin_preserves_ownership_and_nil_deletes
      map_classes.each do |klass|
        map = klass.new { { key: Object.new } }
        original = map.checkout(:key)

        [true, false].each do |invalid|
          assert_raises(ArgumentError) { map.checkin(:key, invalid) }
          assert map.owned?(:key)
        end

        assert_same map, map.checkin(:key, nil)
        refute map.key?(:key)
        assert_raises(KeyError) { map.checkout(:key) }
        assert original
      end
    end

    def test_nil_checkin_requires_an_explicit_checkout
      map_classes.each do |klass|
        map = klass.new { { key: Object.new } }

        assert_raises(OwnershipError) { map.checkin(:key, nil) }
        assert map.key?(:key)
      end
    end

    def test_timeout_validation_and_zero_timeout
      map_classes.each do |klass|
        map = klass.new { { key: Object.new } }

        [-1, -Float::INFINITY, Float::INFINITY, Float::NAN].each do |timeout|
          assert_raises(ArgumentError) { map.checkout(:key, timeout:) }
        end

        resource = map.checkout(:key)
        error = Fiber.new do
          assert_raises(TimeoutError) { map.checkout(:key, timeout: 0) }
        end.resume

        assert_instance_of TimeoutError, error
        map.checkin(:key, resource)
      end
    end

    def test_waiting_checkout_acquires_after_checkin
      map_classes.each do |klass|
        map = klass.new { { key: Object.new } }
        resource = map.checkout(:key)
        waiter = Thread.new { map.checkout(:key, timeout: 2) { :acquired } }
        wait_until_waiting(map, waiter)

        map.checkin(:key, resource)

        assert waiter.join(2), "#{klass} key waiter did not wake after checkin"
        assert_equal :acquired, waiter.value
      ensure
        waiter&.kill&.join
      end
    end

    def test_deleting_an_owned_key_wakes_waiters_with_key_error
      map_classes.each do |klass|
        map = klass.new { { key: [] } }
        original = map.checkout(:key)
        waiter = Thread.new do
          map.checkout(:key, timeout: 5)
        rescue StandardError => e
          e
        end
        wait_until_waiting(map, waiter)

        removed = map.delete(:key)

        assert_equal original, removed
        assert waiter.join(2), "#{klass} key waiter did not wake after deletion"
        assert_instance_of KeyError, waiter.value
        refute map.key?(:key)
      ensure
        waiter&.kill&.join
      end
    end

    def test_reads_require_ownership_for_existing_keys
      map_classes.each do |klass|
        map = klass.new { { key: [] } }

        assert_raises(OwnershipError) { map[:key] }
        assert_raises(OwnershipError) { map.fetch(:key) }
        map.checkout(:key) do |resource|
          assert_same resource, map[:key]
          assert_same resource, map.fetch(:key)
          assert_same resource, map.dig(:key) # rubocop:disable Style/SingleArgumentDig
          assert_equal [resource], map.values_at(:key)
        end
        assert_raises(OwnershipError) { map[:key] }
      end
    end

    def test_missing_reads_retain_hash_behavior_without_checkout
      map_classes.each do |klass|
        map = klass.new { {} }

        assert_nil map[:missing]
        assert_equal :default, map.fetch(:missing, :default)
        assert_equal :block, map.fetch(:missing) { :block } # rubocop:disable Style/RedundantFetchBlock
        error = assert_raises(KeyError) { map.fetch(:missing) }

        assert_equal :missing, error.key
        assert_same map, error.receiver
      end
    end

    def test_key_only_inspection_does_not_require_checkout
      map_classes.each do |klass|
        map = klass.new { { first: Object.new, second: Object.new } }
        resource = map.checkout(:first)

        assert map.key?(:first)
        assert_equal 2, map.size
        refute_predicate map, :empty?
        assert_equal %i[first second], map.keys.sort
        assert_equal %i[first second], map.each_key.to_a.sort
        assert_equal :first, map.getkey(:first)
        map.checkin(:first, resource)
      end
    end

    def test_iteration_leases_one_entry_for_each_yield
      map_classes.each do |klass|
        map = klass.new { { first: [:one], second: [:two] } }
        observed = []
        result = map.each_pair do |key, value|
          assert_same value, map[key]
          other_key = key == :first ? :second : :first

          assert_raises(OwnershipError) { map[other_key] }
          observed << [key, value.dup]
        end

        assert_same map, result
        assert_equal [[:first, [:one]], [:second, [:two]]], observed.sort_by(&:first)
        assert_raises(OwnershipError) { map[:first] }
        assert_raises(OwnershipError) { map[:second] }
      end
    end

    def test_assignment_inserts_and_replaces_available_entries
      map_classes.each do |klass|
        map = klass.new { { key: [:initial] } }

        map[:key] = [:replacement]
        map[:inserted] = [:new]

        assert_equal [:replacement], map.checkout(:key, &:dup)
        assert_equal [:new], map.checkout(:inserted, &:dup)
        assert_equal 2, map.size
      end
    end

    def test_assignment_accepts_a_bare_basic_object
      map_classes.each do |klass|
        map = klass.new { {} }

        map[:key] = BasicObject.new

        assert_equal :used, map.checkout(:key) { :used }
      end
    end

    def test_assignment_inside_auto_lease_stays_owned_until_scope_cleanup
      map_classes.each do |klass|
        map = klass.new { { key: [:initial] } }

        map.auto_lease do
          map[:key]
          map[:key] = [:replacement]
          map[:inserted] = [:new]

          assert map.owned?(:key)
          assert map.owned?(:inserted)
          assert_equal [:replacement], map[:key]
          assert_equal [:new], map[:inserted]
        end

        refute map.owned?(:key)
        refute map.owned?(:inserted)
        assert_equal [:replacement], map.checkout(:key, &:dup)
        assert_equal [:new], map.checkout(:inserted, &:dup)
      end
    end

    def test_assignment_waits_for_an_active_owner
      map_classes.each do |klass|
        map = klass.new { { key: [:initial] } }
        entered = ::Queue.new
        release = ::Queue.new
        holder = Thread.new do
          map.checkout(:key) do
            entered << true
            release.pop
          end
        end
        entered.pop
        assignment = Thread.new do
          map[:key] = [:replacement]
          :assigned
        end
        wait_until_waiting(map, assignment)

        refute assignment.join(0), "#{klass} assignment did not wait for the entry owner"
        release << true

        assert holder.join(2), "#{klass} entry holder did not finish"
        assert assignment.join(2), "#{klass} assignment remained blocked"
        assert_equal :assigned, assignment.value
        assert_equal [:replacement], map.checkout(:key, &:dup)
      ensure
        release << true if release
        holder&.kill&.join
        assignment&.kill&.join
      end
    end

    def test_delete_returns_the_removed_value_and_missing_delete_returns_nil
      map_classes.each do |klass|
        map = klass.new { { key: [:initial] } }
        removed = map.delete(:key)

        assert_equal [:initial], removed
        assert_nil map.delete(:missing)
        refute map.key?(:key)
      end
    end

    def test_delete_waits_for_an_active_owner
      map_classes.each do |klass|
        map = klass.new { { key: [:initial] } }
        entered = ::Queue.new
        release = ::Queue.new
        holder = Thread.new do
          map.checkout(:key) do
            entered << true
            release.pop
          end
        end
        entered.pop
        deletion = Thread.new { map.delete(:key) }
        wait_until_waiting(map, deletion)

        refute deletion.join(0), "#{klass} deletion did not wait for the entry owner"
        release << true

        assert holder.join(2), "#{klass} entry holder did not finish"
        assert deletion.join(2), "#{klass} deletion remained blocked"
        assert_equal [:initial], deletion.value
        refute map.key?(:key)
      ensure
        release << true if release
        holder&.kill&.join
        deletion&.kill&.join
      end
    end

    def test_auto_lease_acquires_on_first_read_and_returns_every_entry
      map_classes.each do |klass|
        map = klass.new { { first: [], second: [] } }
        result = map.auto_lease do
          first = map[:first]
          first << :one

          assert_same first, map[:first]
          map.fetch(:second) << :two
          :result
        end

        assert_equal :result, result
        assert_equal [:one], map.checkout(:first, &:dup)
        assert_equal [:two], map.checkout(:second, &:dup)
        assert_raises(OwnershipError) { map[:first] }
      end
    end

    def test_auto_lease_checks_in_after_exception_and_nonlocal_return
      map_classes.each do |klass|
        map = klass.new { { first: [], second: [] } }
        failure = RuntimeError.new("scope failed")
        raised = assert_raises(RuntimeError) do
          map.auto_lease do
            map[:first] << :exception
            map[:second]
            raise failure
          end
        end

        assert_same failure, raised
        assert_equal :returned, return_from_auto_lease(map)
        assert_equal %i[exception returned], map.checkout(:first, &:dup)
        assert map.available?(:second)
      end
    end

    def test_auto_lease_owns_blockless_checkout_and_rejects_direct_checkin
      map_classes.each do |klass|
        map = klass.new { { key: [] } }

        map.auto_lease do
          resource = map.checkout(:key)

          assert_same resource, map[:key]
          assert_raises(OwnershipError) { map.checkin(:key, resource) }
          assert map.owned?(:key)
        end

        assert map.available?(:key)
      end
    end

    def test_failed_auto_checkout_handoff_cannot_capture_a_later_explicit_checkout
      klass = concrete_map_class(Unshared)
      map = klass.new { { key: [] } }
      handle = map.lease_for(:key)
      internal = map.instance_variable_get(:@lease_map)
      failure = RuntimeError.new("handoff failed")
      internal.singleton_class.define_method(:register_context_resource) do |context, lease|
        super(context, lease)
        raise failure
      end
      resource = nil

      map.auto_lease do
        assert_same failure, assert_raises(RuntimeError) { map[:key] }
        resource = handle.checkout
      end

      assert_predicate handle, :owned?
      handle.checkin(resource)
    end

    def test_rescued_recursive_checkout_preserves_auto_cleanup
      map_classes.each do |klass|
        map = klass.new { { key: [] } }

        map.auto_lease do
          map[:key]

          assert_raises(ThreadError) { map.checkout(:key) }
          assert_raises(ThreadError) { map.try_checkout(:key) }
          assert map.owned?(:key)
        end

        assert map.available?(:key)
      end
    end

    def test_canceling_auto_lease_while_waiting_leaves_no_checkout
      map_classes.each do |klass|
        map = klass.new { { key: Object.new } }
        resource = map.checkout(:key)
        waiter = Thread.new { map.auto_lease { map[:key] } }
        wait_until_waiting(map, waiter)

        waiter.kill

        assert waiter.join(2), "#{klass} canceled auto lease did not finish"
        map.checkin(:key, resource)

        assert map.available?(:key)
      ensure
        waiter&.kill&.join
      end
    end

    def test_nested_auto_lease_preserves_outer_and_preexisting_ownership
      map_classes.each do |klass|
        map = klass.new { { explicit: [], outer: [], inner: [] } }
        explicit = map.checkout(:explicit)
        map.auto_lease do
          outer = map[:outer]
          map.auto_lease do
            assert_same outer, map[:outer]
            map[:inner]
          end

          assert_same outer, map[:outer]
          refute map.owned?(:inner)
        end

        assert map.owned?(:explicit)
        refute map.owned?(:outer)
        refute map.owned?(:inner)
        map.checkin(:explicit, explicit)
      end
    end

    def test_auto_lease_does_not_extend_to_another_fiber
      map_classes.each do |klass|
        map = klass.new { { key: Object.new } }

        map.auto_lease do
          map[:key]
          error = Fiber.new { assert_raises(OwnershipError) { map[:key] } }.resume

          assert_instance_of OwnershipError, error
        end
      end
    end

    def test_lease_for_shares_ownership_with_map_access
      map_classes.each do |klass|
        map = klass.new { { key: [] } }
        handle = map.lease_for(:key)

        result = handle.checkout do |resource|
          assert_same resource, map[:key]
          assert_raises(ThreadError) { map.checkout(:key, timeout: 0) }
          :result
        end

        assert_equal :result, result
        assert_raises(KeyError) { map.lease_for(:missing) }
      end
    end

    def test_deleted_handle_retires_and_reinsertion_creates_a_fresh_handle
      map_classes.each do |klass|
        map = klass.new { { key: [:initial] } }
        stale = map.lease_for(:key)
        removed = map.delete(:key)

        assert_equal [:initial], removed
        assert_predicate stale, :retired?
        assert_raises(RetiredLeaseError) { stale.checkout }
        map[:key] = [:replacement]
        current = map.lease_for(:key)

        refute_same stale, current
        assert_raises(RetiredLeaseError) { stale.checkout }
        assert_equal [:replacement], current.checkout(&:dup)
      end
    end

    def test_conversions_return_current_lease_handles
      map_classes.each do |klass|
        map = klass.new { { first: [], second: [] } }
        handles = map.to_h

        assert_same map.lease_for(:first), handles.fetch(:first)
        assert_same map.lease_for(:second), handles.fetch(:second)
        assert_equal handles, map.to_a.to_h
        assert_equal handles.values.sort_by(&:object_id), map.values.sort_by(&:object_id)
      end
    end

    def test_direct_handle_retirement_removes_membership_on_observation
      map_classes.each do |klass|
        map = klass.new { { key: Object.new } }
        handle = map.lease_for(:key)

        handle.checkout
        handle.retire

        refute map.key?(:key)
        refute_includes map.keys, :key
        assert_raises(KeyError) { map.lease_for(:key) }
      end
    end

    def test_clear_does_not_remove_an_entry_reinserted_during_wait
      map_classes.each do |klass|
        map = klass.new { { key: [:initial] } }
        stale = map.lease_for(:key)
        stale.checkout
        clearing = Thread.new { map.clear }
        wait_until_waiting(map, clearing)

        stale.retire
        map[:key] = [:replacement]

        assert clearing.join(2), "#{klass} clear remained blocked"
        assert_equal [:replacement], map.checkout(:key, &:dup)
      ensure
        clearing&.kill&.join
      end
    end

    def test_top_level_distinct_entries_transfer_concurrently
      klass = concrete_map_class(Farce)
      map = klass.new { (0...20).to_h { |index| [index, []] } }

      10.times do
        workers = 20.times.map do |index|
          Thread.new { map.checkout(index) { |resource| resource << index } }
        end
        workers.each { assert it.join(2), "distinct entry checkout did not finish" }
      ensure
        workers&.each { it.kill.join }
      end

      20.times { |index| assert_equal [index] * 10, map.checkout(index, &:dup) }
    end

    def test_top_level_map_is_shareable
      klass = concrete_map_class(Farce)
      map = klass.new { {} }

      assert_predicate map, :frozen?
      assert_predicate map, :ractor_shareable?
      assert Ractor.shareable?(map)
    end

    def test_local_map_is_shareable
      klass = concrete_map_class(Local)
      map = klass.new { {} }

      assert_predicate map, :frozen?
      assert_predicate map, :ractor_shareable?
      assert Ractor.shareable?(map)
    end

    def test_unshared_map_is_unshareable
      klass = concrete_map_class(Unshared)
      map = klass.new { {} }

      refute_predicate map, :ractor_shareable?
      refute Ractor.shareable?(map)
      assert_raises(NoMethodError) { map.freeze }
    end

    def test_top_level_map_transfers_entries_across_ractors
      klass = concrete_map_class(Farce)
      map = klass.new { { key: [] } }
      worker = Ractor.new(map) do |shared|
        shared.checkout(:key) do |resource|
          resource << :worker
          :done
        end
      end

      assert_equal :done, ractor_value(worker)
      assert_equal [:worker], map.checkout(:key, &:dup)
    end

    def test_unshared_map_passes_entry_references_directly
      klass = concrete_map_class(Unshared)
      resource = []
      map = klass.new { { key: resource } }

      assert_same resource, map.checkout(:key, &:itself)
      explicit = map.checkout(:key)
      map.checkin(:key, explicit)

      assert_same resource, map.checkout(:key, &:itself)
    end

    def test_local_map_initializes_once_per_scope_and_retries_failure
      klass = concrete_map_class(Local)
      calls = Counter.new
      map = klass.new do
        raise "not ready" if calls.increment.value == 1
        { key: [] }
      end

      assert_raises(RuntimeError) { map.size }
      assert_equal 1, map.size
      assert_equal 2, calls.value
      workers = 4.times.map { Thread.new { map.checkout(:key, timeout: 2, &:object_id) } }
      object_ids = workers.map(&:value)

      assert_equal 1, object_ids.uniq.length
      assert_equal 2, calls.value
    ensure
      workers&.each { it.kill.join }
    end

    def test_local_map_has_independent_entries_per_fiber_scope
      klass = concrete_map_class(Local)
      calls = Counter.new
      map = klass.new(scope: :fiber) do
        calls.increment
        { key: [] }
      end
      map.checkout(:key) { it << :parent }
      handle = map.lease_for(:key)
      child = Fiber.new do
        scoped = map.checkout(:key) { |resource| [resource.dup, resource.object_id] }
        attached = handle.checkout { |resource| [resource.dup, resource.object_id] }
        [scoped, attached]
      end.resume
      parent = map.checkout(:key) { |resource| [resource.dup, resource.object_id] }

      assert_empty child.fetch(0).fetch(0)
      assert_equal parent, child.fetch(1)
      refute_equal parent.fetch(1), child.fetch(0).fetch(1)
      assert_equal 2, calls.value
    end

    def test_local_map_supports_all_scopes
      klass = concrete_map_class(Local)
      %i[ractor thread_group thread fiber_storage fiber].each do |scope|
        map = klass.new(scope:) { {} }

        assert_equal scope, map.scope
      end

      assert_raises(ArgumentError) { klass.new(scope: :invalid) { {} } }
    end

    def test_store_if_absent_obeys_ownership_and_resource_validation
      map_classes.each do |klass|
        map = klass.new { { existing: [] } }
        assert_raises(LocalJumpError) { map.store_if_absent(:existing) }
        assert_raises(OwnershipError) { map.store_if_absent(:missing) { flunk "constructor ran without scope" } }
        assert_raises(OwnershipError) { map.store_if_absent(:existing) { flunk "existing constructor ran" } }
        map.checkout(:existing) do |resource|
          assert_same resource, map.store_if_absent(:existing) { flunk "existing constructor ran" }
        end
        map.auto_lease do
          [nil, true, false].each do |invalid|
            assert_raises(ArgumentError) { map.store_if_absent(:missing) { invalid } }
            refute map.key?(:missing)
          end
          resource = map.store_if_absent(:missing) { [:created] }

          assert_equal [:created], resource
          assert_same resource, map[:missing]
          assert map.owned?(:missing)
          assert_same resource, map.store_if_absent(:missing) { flunk "constructor repeated" }
        end
        assert map.available?(:missing)
      end
    end

    def test_store_if_absent_coordinates_constructors_and_assignments
      map_classes.each do |klass|
        map         = klass.new { {} }
        entered     = ::Queue.new
        release     = ::Queue.new
        created     = ::Queue.new
        leave_scope = ::Queue.new
        calls       = Counter.new
        owner       = Thread.new do
          map.auto_lease do
            resource = map.store_if_absent(:key) do
              calls.increment
              entered << true
              release.pop
              [:created]
            end
            created << resource.dup
            leave_scope.pop
          end
        end
        entered.pop
        waiter = Thread.new do
          map.auto_lease do
            map.store_if_absent(:key) do
              calls.increment
              [:duplicate]
            end.dup
          end
        end
        writer = Thread.new { map[:key] = [:replacement] }

        refute waiter.join(0.01), "competing constructor did not wait"
        refute writer.join(0.01), "assignment did not wait for construction"
        map[:other] = [:unrelated]

        assert_equal [:unrelated], map.checkout(:other, &:dup)
        refute map.key?(:key)
        assert_nil map.delete(:key)
        map.clear
        release << true

        assert_equal [:created], created.pop
        assert_equal 1, calls.value
        leave_scope << true
        owner.value
        writer.value

        assert_includes [[:created], [:replacement]], waiter.value
        assert_equal 1, calls.value
        assert_equal [:replacement], map.checkout(:key, &:dup)
      ensure
        owner&.kill&.join
        waiter&.kill&.join
        writer&.kill&.join
      end
    end

    def test_store_if_absent_cancellation_recursion_and_retirement
      map_classes.each do |klass|
        map = klass.new { {} }
        entered = ::Queue.new
        owner = Thread.new do
          map.auto_lease do
            map.store_if_absent(:key) do
              entered << true
              sleep
            end
          end
        end
        entered.pop
        owner.kill.join

        refute map.key?(:key)
        map.auto_lease do
          assert_raises(ThreadError) { map.store_if_absent(:key) { map.store_if_absent(:key) { [] } } }
          assert_raises(ThreadError) { map.store_if_absent(:key) { map[:key] = [] } }
          assert_raises(RuntimeError) { map.store_if_absent(:key) { raise "failed" } }
          assert_equal :left, catch(:leave) { map.store_if_absent(:key) { throw :leave, :left } }
          assert_equal [], map.store_if_absent(:key) { [] }
          map.lease_for(:key).retire

          assert_equal [:new], map.store_if_absent(:key) { [:new] }
        end
        assert map.available?(:key)
      ensure
        owner&.kill&.join
      end
    end

    def test_store_if_absent_creates_resource_from_another_ractor
      map = Farce::LeaseMap.new { {} }
      worker = Ractor.new(map) do |shared|
        shared.auto_lease do
          shared.store_if_absent(:key) { [:worker] } << :changed
          :done
        end
      end

      assert_equal :done, ractor_value(worker)
      assert_equal %i[worker changed], map.checkout(:key, &:dup)
    end

    private

    def map_classes = MAP_CLASSES

    def direct_map_classes
      MAP_CLASSES.reject { it.name == "Farce::Local::LeaseMap" }
    end

    def concrete_map_class(namespace)
      namespace.const_get(:LeaseMap, false)
    end

    def return_from_checkout(map)
      map.checkout(:key) do |resource|
        resource << :returned
        return :returned
      end

      flunk "checkout ignored a nonlocal return"
    end

    def return_from_auto_lease(map)
      map.auto_lease do
        map[:first] << :returned
        map[:second]
        return :returned
      end

      flunk "auto_lease ignored a nonlocal return"
    end

    def wait_until_waiting(map, thread)
      lease = map.lease_for(:key)
      signal = lease.__send__(:internal_lease).instance_variable_get(:@signal)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      # A sleeping thread may only be acquiring an unrelated internal mutex.
      # Wait for registration on this entry's signal before releasing its owner.
      waiting = -> { signal.num_waiting.positive? }
      sleep 0.001 until waiting.call || !thread.alive? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      thread.value unless thread.alive?

      assert waiting.call, "#{map.class} thread did not block while waiting for the map entry"
    end
  end
end
