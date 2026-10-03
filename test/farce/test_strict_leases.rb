# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestStrictLease < Test
    include Helpers::InternalTestHelpers

    def run(...) = Timeout.timeout(10) { super }

    def test_public_contract_and_direct_identity
      resource = Strict::Map.new
      lease = Strict::Lease.new { resource }

      assert_equal Abstract::Lease, Strict::Lease.superclass
      assert Ractor.shareable?(lease)
      assert_predicate lease, :ractor_shareable?
      refute_predicate lease, :frozen?
      assert_raises(TypeError) { lease.freeze }
      assert_raises(TypeError) { lease.dup }
      assert_raises(ArgumentError) { Strict::Lease.new }
      assert_raises(ArgumentError) { Strict::Lease.new(mode: :copy) { resource } }
      assert_same(resource, lease.checkout { it })
      refute_predicate resource, :frozen?
    end

    def test_constructor_rejects_invalid_resources
      [nil, true, false].each do |resource|
        assert_raises(ArgumentError) { Strict::Lease.new { resource } }
      end
      assert_raises(Ractor::IsolationError) { Strict::Lease.new { Unshared::Queue.new } }
      return unless Internal.native_ractors?

      resource = []

      assert_raises(Ractor::IsolationError) { Strict::Lease.new { resource } }
      refute_predicate resource, :frozen?
    end

    def test_rejected_checkin_preserves_ownership_and_original_resource
      resource = Strict::Map.new
      lease = Strict::Lease.new { resource }

      assert_same resource, lease.checkout
      [nil, true, false].each { |invalid| assert_raises(ArgumentError) { lease.checkin(invalid) } }
      assert_raises(Ractor::IsolationError) { lease.checkin(Unshared::Queue.new) }
      assert_predicate lease, :owned?
      replacement = Strict::Map.new

      assert_same lease, lease.checkin(replacement)
      assert_same(replacement, lease.checkout { it })
      resource[:retained] = :usable
      replacement[:retained] = :usable

      assert_equal :usable, resource[:retained]
      assert_equal(:usable, lease.checkout { it[:retained] })
    end

    def test_exception_cleanup_recursion_and_retirement
      resource = Strict::Map.new
      lease = Strict::Lease.new { resource }

      assert_raises(RuntimeError) do
        lease.checkout do |state|
          state[:updated] = true
          assert_raises(ThreadError) { lease.checkout }
          raise "failed use"
        end
      end
      assert_predicate lease, :available?
      assert(lease.checkout { it[:updated] })
      assert_same resource, lease.try_checkout
      assert_raises(OwnershipError) { Fiber.new { lease.checkin(resource) }.resume }
      lease.retire

      assert_predicate lease, :retired?
      refute_predicate lease, :owned?
      assert_raises(RetiredLeaseError) { lease.checkout }
      assert_same lease, lease.retire
    end

    def test_contended_checkout_timeout_and_thread_handoff
      resource = Strict::Map.new
      lease = Strict::Lease.new { resource }
      lease.checkout
      ready = ::Queue.new
      worker = Thread.new do
        unavailable = lease.try_checkout
        timed_out = begin
          lease.checkout(timeout: 0)
          false
        rescue TimeoutError
          true
        end
        ready << [unavailable, timed_out]
        lease.checkout { |state| state[:worker] = :done }
      end

      assert_equal [nil, true], ready.pop
      lease.checkin(resource)

      assert_equal :done, worker.value
      assert_equal :done, resource[:worker]
      assert_predicate lease, :available?
    ensure
      worker&.kill if worker&.alive?
      worker&.join
    end

    def test_cross_ractor_checkout_keeps_the_same_reference
      resource = Strict::Map.new
      lease = Strict::Lease.new { resource }
      worker = Ractor.new(lease) do |shared|
        shared.checkout do |state|
          state[:worker] = :done
          state.object_id
        end
      end

      assert_equal resource.object_id, ractor_value(worker)
      assert_equal :done, resource[:worker]
      assert_same(resource, lease.checkout { it })
    end

    def test_strict_lease_family_supports_scheduled_fiber_waits
      return unless Fiber.respond_to?(:set_scheduler)

      services = [
        Strict::Lease.new { :resource },
        Strict::LeasePool.new(max_size: 1) { :resource },
        Strict::LeaseMap.new { { key: :resource } }
      ]
      services.each do |service|
        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        arguments = service.is_a?(Abstract::LeaseMap) ? [:key] : []
        events = []
        holding = Signal.new
        release = Signal.new
        Fiber.schedule do
          service.checkout(*arguments) do
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
          service.checkout(*arguments, timeout: 1) { events << :acquired }
        end
        Fiber.set_scheduler(nil)

        assert_equal %i[holding waiting releasing acquired], events
        assert_operator scheduler.io_wait_calls + scheduler.block_calls, :>=, 1
      ensure
        Fiber.set_scheduler(nil) if Fiber.scheduler
      end
    end

    def test_strict_lease_family_never_uses_the_vault
      output, error, status = ruby_isolated(<<~RUBY)
        require "farce"
        internal = Farce.const_get(:Internal)
        before = internal.autoload?(:Vault)
        unless before
          internal.const_get(:Vault).class_eval do
            def initialize(*) = raise("Vault was used")
            def move_in(*) = raise("Vault was used")
            def move_out(*) = raise("Vault was used")
            def delete(*) = raise("Vault was used")
          end
        end
        lease = Farce::Strict::Lease.new { :initial }
        lease.checkout
        lease.checkin(:replacement)
        lease.checkout { |resource| raise unless resource == :replacement }
        pool = Farce::Strict::LeasePool.new(max_size: 1) { :initial }
        pool.checkout
        pool.checkin(:replacement)
        pool.checkout { |resource| raise unless resource == :replacement }
        map = Farce::Strict::LeaseMap.new { { key: :initial } }
        map.auto_lease { map[:key] = :replacement }
        raise unless map.delete(:key) == :replacement
        raise "Vault was loaded" unless internal.autoload?(:Vault) == before
        puts "direct"
      RUBY

      assert_predicate status, :success?, error
      assert_equal "direct\n", output
    end
  end

  class TestStrictLeasePool < Test
    include Helpers::InternalTestHelpers

    def run(...) = Timeout.timeout(10) { super }

    def test_public_contract_and_resource_reuse
      pool = Strict::LeasePool.new(max_size: 2) { Strict::Map.new }

      assert_equal Abstract::LeasePool, Strict::LeasePool.superclass
      assert Ractor.shareable?(pool)
      refute_predicate pool, :frozen?
      assert_raises(TypeError) { pool.freeze }
      assert_raises(TypeError) { pool.dup }
      assert_raises(ArgumentError) { Strict::LeasePool.new(max_size: 1) }
      assert_raises(ArgumentError) { Strict::LeasePool.new(max_size: 0) { :value } }
      assert_equal 0, pool.size
      resource = pool.checkout

      assert_equal 1, pool.size
      assert_equal 1, pool.checked_out_count
      assert_same pool, pool.checkin(resource)
      assert_same(resource, pool.checkout { it })
      refute_predicate resource, :frozen?
    end

    def test_invalid_factory_results_release_creation_capacity
      [nil, true, false].each do |invalid|
        pool = Strict::LeasePool.new(max_size: 1) { invalid }

        assert_raises(ArgumentError) { pool.checkout }
        assert_equal [0, 0, 0, 0], [pool.size, pool.creating_count, pool.checked_out_count, pool.available_count]
      end
      calls = Counter.new
      pool = Strict::LeasePool.new(max_size: 1) do
        calls.increment == 1 ? Unshared::Queue.new : Strict::Map.new
      end

      assert_raises(Ractor::IsolationError) { pool.checkout }
      assert_equal [0, 0, 0, 0], [pool.size, pool.creating_count, pool.checked_out_count, pool.available_count]
      resource = pool.checkout

      assert_instance_of Strict::Map, resource
      pool.checkin(resource)

      assert_equal 1, pool.available_count
    end

    def test_mutable_factory_result_and_checkin_are_rejected_without_freezing
      return unless Internal.native_ractors?

      pool = Strict::LeasePool.new(max_size: 1) { [] }

      assert_raises(Ractor::IsolationError) { pool.try_checkout }
      assert_equal [0, 0, 0], [pool.size, pool.creating_count, pool.checked_out_count]
      pool = Strict::LeasePool.new(max_size: 1) { :resource }
      resource = pool.checkout
      rejected = []

      assert_raises(Ractor::IsolationError) { pool.checkin(rejected) }
      refute_predicate rejected, :frozen?
      pool.checkin(resource)

      assert_equal(:resource, pool.checkout { it })
    end

    def test_rejected_checkin_preserves_the_slot_and_allows_replacement
      pool = Strict::LeasePool.new(max_size: 1) { Strict::Map.new }
      original = pool.checkout

      [true, false].each { |invalid| assert_raises(ArgumentError) { pool.checkin(invalid) } }
      assert_raises(Ractor::IsolationError) { pool.checkin(Unshared::Queue.new) }
      assert_equal [1, 1, 0], [pool.size, pool.checked_out_count, pool.available_count]
      replacement = Strict::Map.new
      pool.checkin(replacement)

      assert_same(replacement, pool.checkout { it })
      original[:retained] = true
      replacement[:retained] = true

      assert original[:retained]
      assert(pool.checkout { it[:retained] })
    end

    def test_multiple_checkouts_exhaustion_and_nil_discard
      pool = Strict::LeasePool.new(max_size: 2) { Strict::Map.new }
      first = pool.checkout
      second = pool.checkout

      refute_same first, second
      assert_nil pool.try_checkout
      assert_raises(TimeoutError) { pool.checkout(timeout: 0) }
      assert_raises(OwnershipError) { Fiber.new { pool.checkin(first) }.resume }
      pool.checkin(nil)
      pool.checkin(first)

      assert_equal [1, 0, 1], [pool.size, pool.checked_out_count, pool.available_count]
      assert_same(first, pool.checkout { it })
      pool.checkout
      replacement = pool.checkout

      refute_same second, replacement
      assert_equal 2, pool.size
      pool.checkin(nil)
      pool.checkin(nil)

      assert_equal 0, pool.size
    end

    def test_block_exception_restores_the_same_resource
      pool = Strict::LeasePool.new(max_size: 1) { Strict::Map.new }
      resource = nil

      assert_raises(RuntimeError) do
        pool.checkout do |state|
          resource = state
          state[:changed] = true
          raise "failed use"
        end
      end
      assert_equal [1, 0, 1], [pool.size, pool.checked_out_count, pool.available_count]
      assert_same(resource, pool.try_checkout { it })
      assert resource[:changed]
    end

    def test_factory_and_reuse_across_ractors
      pool = Strict::LeasePool.new(max_size: 1) { Strict::Map.new }
      worker = Ractor.new(pool) do |shared|
        shared.checkout do |resource|
          resource[:worker] = :done
          resource.object_id
        end
      end
      identity = ractor_value(worker)
      resource = pool.checkout { it }

      assert_equal identity, resource.object_id
      assert_equal :done, resource[:worker]
      assert_equal 1, pool.size
    end
  end

  class TestStrictLeaseMap < Test
    include Helpers::InternalTestHelpers

    def run(...) = Timeout.timeout(10) { super }

    def test_public_contract_and_strict_handles
      resource = Strict::Map.new
      map = Strict::LeaseMap.new { { key: resource } }

      assert_equal Abstract::LeaseMap, Strict::LeaseMap.superclass
      assert Ractor.shareable?(map)
      assert_predicate map, :shareable_values?
      refute_predicate map, :frozen?
      assert_raises(TypeError) { map.freeze }
      assert_raises(TypeError) { map.dup }
      assert_raises(ArgumentError) { Strict::LeaseMap.new }
      assert_instance_of Strict::Lease, map.lease_for(:key)
      assert_same resource, map.checkout(:key) { it }
      refute_predicate resource, :frozen?
      assert_raises(OwnershipError) { map[:key] }
    end

    def test_constructor_rejects_invalid_resources
      [nil, true, false].each do |invalid|
        assert_raises(ArgumentError) { Strict::LeaseMap.new { { key: invalid } } }
      end
      assert_raises(Ractor::IsolationError) do
        Strict::LeaseMap.new { { key: Unshared::Queue.new } }
      end
      return unless Internal.native_ractors?

      assert_raises(Ractor::IsolationError) { Strict::LeaseMap.new { { key: [] } } }
    end

    def test_rejected_insertions_and_replacements_preserve_entries_and_ownership
      resource = Strict::Map.new
      map = Strict::LeaseMap.new { { key: resource } }
      rejected = Unshared::Queue.new

      assert_raises(Ractor::IsolationError) { map[:missing] = rejected }
      refute map.key?(:missing)
      assert_raises(Ractor::IsolationError) { map[:key] = rejected }
      assert map.available?(:key)
      assert_same resource, map.checkout(:key)
      assert_raises(Ractor::IsolationError) { map[:key] = rejected }
      assert_raises(Ractor::IsolationError) { map.checkin(:key, rejected) }
      assert map.owned?(:key)
      assert_same resource, map[:key]
      replacement = Strict::Map.new
      map[:key] = replacement

      assert_same replacement, map[:key]
      map.checkin(:key, replacement)

      assert_same replacement, map.checkout(:key) { it }
    end

    def test_mutable_insertions_and_checkin_are_rejected_without_freezing
      return unless Internal.native_ractors?

      map = Strict::LeaseMap.new { { key: :resource } }
      rejected = []

      assert_raises(Ractor::IsolationError) { map[:missing] = rejected }
      assert_raises(Ractor::IsolationError) { map[:key] = rejected }
      assert_equal :resource, map.checkout(:key)
      assert_raises(Ractor::IsolationError) { map.checkin(:key, rejected) }
      refute_predicate rejected, :frozen?
      assert map.owned?(:key)
      map.checkin(:key, :resource)

      assert map.available?(:key)
    end

    def test_nested_automatic_scopes_and_exception_cleanup
      first = Strict::Map.new
      second = Strict::Map.new
      map = Strict::LeaseMap.new { { first:, second: } }

      assert_raises(RuntimeError) do
        map.auto_lease do
          assert_same first, map[:first]
          map.auto_lease do
            assert_same first, map[:first]
            assert_same second, map[:second]
            second[:changed] = true
          end

          assert map.owned?(:first)
          assert map.available?(:second)
          assert_raises(Ractor::IsolationError) { map[:first] = Unshared::Queue.new }
          assert_same first, map[:first]
          raise "failed use"
        end
      end
      assert map.available?(:first)
      assert map.available?(:second)
      assert second[:changed]
    end

    def test_store_if_absent_rejection_is_retryable
      map = Strict::LeaseMap.new { {} }
      map.auto_lease do
        assert_raises(Ractor::IsolationError) { map.store_if_absent(:key) { Unshared::Queue.new } }
        refute map.key?(:key)
        resource = map.store_if_absent(:key) { Strict::Map.new }

        assert_same resource, map[:key]
        assert map.owned?(:key)
        assert_same resource, map.store_if_absent(:key) { raise "must not run" }
      end

      assert map.available?(:key)
    end

    def test_deletion_retires_old_handles_and_reinsertion_is_independent
      resource = Strict::Map.new
      map = Strict::LeaseMap.new { { key: resource } }
      old = map.lease_for(:key)

      assert_same resource, map.delete(:key)
      assert_predicate old, :retired?
      assert_raises(RetiredLeaseError) { old.checkout }
      replacement = Strict::Map.new
      map[:key] = replacement

      refute_same old, map.lease_for(:key)
      assert_same replacement, map.checkout(:key)
      map.checkin(:key, nil)

      refute map.key?(:key)
      assert_empty map
    end

    def test_normalized_keys_iteration_and_clear
      resource = Strict::Map.new
      map = Strict::LeaseMap.new(normalize_keys: :downcase) { { "KEY" => resource } }

      assert_same resource, map.checkout("KeY") { it }
      map.auto_lease { map["OTHER"] = :second }
      entries = {}
      map.each { |key, value| entries[key] = value }

      assert_equal({ "key" => resource, "other" => :second }, entries)
      handles = map.values
      map.clear

      assert_empty map
      assert(handles.all?(&:retired?))
    end

    def test_cross_ractor_auto_lease_keeps_resource_identity
      resource = Strict::Map.new
      map = Strict::LeaseMap.new { { key: resource } }
      worker = Ractor.new(map) do |shared|
        shared.auto_lease do
          shared[:key][:worker] = :done
          shared.store_if_absent(:created) { Strict::Map.new }[:worker] = :created
          shared[:key].object_id
        end
      end

      assert_equal resource.object_id, ractor_value(worker)
      assert_equal :done, resource[:worker]
      assert_equal :created, map.checkout(:created) { it[:worker] }
      assert map.available?(:key)
      assert map.available?(:created)
    end
  end
end
