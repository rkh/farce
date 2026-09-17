# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../../setup"
require "objspace" if RUBY_ENGINE == "ruby"

module Farce
  module Internal
    class TestKeyLockMap < Test
      include Helpers::InternalTestHelpers

      def run(...) = Timeout.timeout(10) { super }

      def test_results_and_all_exit_paths_release_without_retained_entries
        [Farce::Map, Strict::Map, Unshared::Map].each do |registry_class|
          locks = KeyLockMap.new(registry_class:)
          result = []

          assert_same result, locks.synchronize(:key) { result }
          assert_raises(LocalJumpError) { locks.synchronize(:key) }
          assert_raises(RuntimeError) { locks.synchronize(:key) { raise "failed" } }
          assert_equal :returned, return_from_lock(locks)
          assert_equal :thrown, catch(:exit) { locks.synchronize(:key) { throw :exit, :thrown } }
          assert_raises(ThreadError) do
            locks.synchronize(:key) do
              locks.synchronize(:key) do
                flunk "recursive lock entered"
              end
            end
          end
          assert_equal :released, locks.synchronize(:key) { :released }
          assert_idle locks
        end
      end

      def test_equal_keys_coordinate_but_identity_keys_remain_independent
        [Farce::Map, Strict::Map, Unshared::Map].each do |registry_class|
          first = [1].freeze
          second = [1].freeze
          locks = KeyLockMap.new(registry_class:)
          assert_raises(ThreadError) do
            locks.synchronize(first) do
              locks.synchronize(second) do
                flunk "equal key lock entered"
              end
            end
          end
          locks = KeyLockMap.new(registry_class:, compare_keys_by_identity: true)

          assert_equal :independent, locks.synchronize(first) { locks.synchronize(second) { :independent } }
        end
      end

      def test_cancellation_releases_waiters_and_unrelated_keys_progress
        [Farce::Map, Strict::Map, Unshared::Map].each do |registry_class|
          locks = KeyLockMap.new(registry_class:)
          entered = ::Queue.new
          owner = Thread.new do
            locks.synchronize(:key) do
              entered << true
              sleep
            end
          end
          entered.pop
          waiter = Thread.new { locks.synchronize(:key) { :released } }

          assert_equal :other, locks.synchronize(:other) { :other }
          owner.kill.join

          assert_equal :released, waiter.value
          assert_idle locks
        ensure
          owner&.kill&.join
          waiter&.kill&.join
        end
      end

      def test_shared_registry_makes_the_helper_shareable
        locks = KeyLockMap.new(registry_class: Farce::Map)

        assert Ractor.shareable?(locks)
        refute_predicate KeyLockMap.new(registry_class: Unshared::Map), :frozen?
        refute Ractor.shareable?(KeyLockMap.new(registry_class: Unshared::Map)) if RUBY_ENGINE == "ruby"
      end

      def test_cross_ractor_waiters_resume_after_owner_cancellation
        locks = KeyLockMap.new(registry_class: Farce::Map)
        events = Farce::Queue.new
        cancel = Farce::Queue.new
        owner = Ractor.new(locks, events, cancel) do |shared, reports, cancellation|
          thread = Thread.new do
            shared.synchronize(:key) do
              reports.push(:owned)
              sleep
            end
          end
          cancellation.pop
          thread.kill.join
          :canceled
        end

        assert_equal :owned, events.pop(timeout: 2)
        waiters = 2.times.map do
          Ractor.new(locks, events) do |shared, reports|
            reports.push(:waiting)
            shared.synchronize(:key) { reports.push(:acquired) }
            :done
          end
        end

        2.times { assert_equal :waiting, events.pop(timeout: 2) }
        unrelated = Ractor.new(locks) { |shared| shared.synchronize(:other) { :independent } }

        assert_equal :independent, ractor_value(unrelated)
        assert_nil events.pop(timeout: 0.02), "a waiter entered while another Ractor owned the key"
        GC.verify_compaction_references(double_heap: true, toward: :empty) if RUBY_ENGINE == "ruby"
        cancel.push(true)

        assert_equal :canceled, ractor_value(owner)
        2.times { assert_equal :acquired, events.pop(timeout: 2) }
        waiters.each { assert_equal :done, ractor_value(it) }

        assert_idle locks
        assert_equal :released, locks.synchronize(:key) { :released }
      ensure
        cancel&.push(true)
      end

      def test_scheduled_fibers_wait_per_key_and_release_after_exception
        return unless RUBY_ENGINE == "ruby" && Fiber.respond_to?(:set_scheduler)

        [Farce::Map, Strict::Map, Unshared::Map].each do |registry_class|
          locks = KeyLockMap.new(registry_class:)
          events = []
          scheduler = Helpers::QueueTestScheduler.new
          Fiber.set_scheduler(scheduler)
          Fiber.schedule do
            locks.synchronize(:key) do
              events << :owned
              Fiber.scheduler.kernel_sleep(0.02)
              raise "cancel constructor"
            end
          rescue RuntimeError
            events << :canceled
          end
          Fiber.schedule do
            events << :waiting
            locks.synchronize(:key) { events << :acquired }
          end
          Fiber.schedule { locks.synchronize(:other) { events << :independent } }
          Fiber.set_scheduler(nil)

          assert_equal %i[owned waiting independent canceled acquired], events
          assert_operator scheduler.io_wait_calls, :>=, 1
          assert_idle locks
        ensure
          Fiber.set_scheduler(nil) if Fiber.scheduler
        end
      end

      def test_unscheduled_fiber_cannot_wait_for_its_suspended_sibling
        [Farce::Map, Strict::Map, Unshared::Map].each do |registry_class|
          locks = KeyLockMap.new(registry_class:)
          owner = Fiber.new do
            locks.synchronize(:key) do
              Fiber.yield :owned
              :released
            end
          end

          assert_equal :owned, owner.resume
          assert_raises(ThreadError) { locks.synchronize(:key) { flunk "entered occupied key" } }
          assert_equal :independent, locks.synchronize(:other) { :independent }
          assert_equal :released, owner.resume
          assert_idle locks
        ensure
          owner.resume if owner&.alive?
        end
      end

      def test_kill_and_raise_cancel_waiters_before_owner_finishes
        [Farce::Map, Strict::Map, Unshared::Map].each do |registry_class|
          locks = KeyLockMap.new(registry_class:)
          entered = ::Queue.new
          release = ::Queue.new
          owner = Thread.new do
            locks.synchronize(:key) do
              entered << true
              release.pop
            end
          end
          entered.pop
          killed = Thread.new { locks.synchronize(:key) { flunk "canceled waiter entered" } }

          refute killed.join(0.1)
          killed.kill

          assert killed.join(1), "killed waiter needed the owner's release"
          raised = Thread.new do
            locks.synchronize(:key) { flunk "raised waiter entered" }
          rescue RuntimeError
            :canceled
          end

          refute raised.join(0.1)
          raised.raise(RuntimeError, "cancel waiting")

          assert raised.join(1), "raised waiter needed the owner's release"
          assert_equal :canceled, raised.value
          survivor = Thread.new { locks.synchronize(:key) { :survived } }

          refute survivor.join(0.05), "cancellation split the owner's gate"
          release << true
          owner.value

          assert_equal :survived, survivor.value
          assert_idle locks
        ensure
          release << true if release
          [owner, killed, raised, survivor].compact.each { it.kill.join if it.alive? }
        end
      end

      def test_registry_timeouts_are_not_shortened_to_cancellation_intervals
        [Farce::Map, Strict::Map, Unshared::Map].each do |registry_class|
          registry = registry_class.new
          entered = ::Queue.new
          release = ::Queue.new
          owner = Thread.new do
            registry.store_if_absent(:key) do
              entered << true
              release.pop
              :created
            end
          end
          entered.pop
          started = Clock.now
          result = registry.store_if_absent(:key, timeout: 0.16) { flunk "timed-out loader entered" }
          elapsed = Clock.now - started

          assert_nil result
          assert_operator elapsed, :>=, 0.14
          assert_operator elapsed, :<, 1
          survivor = Thread.new { registry.store_if_absent(:key, timeout: 1) { flunk "duplicate loader" } }
          release << true
          owner.value

          assert_equal :created, survivor.value
        ensure
          release << true if release
          [owner, survivor].compact.each { it.kill.join if it.alive? }
        end
      end

      private

      def assert_idle(locks)
        if (registry = locks.instance_variable_get(:@registry))
          assert_empty registry
        else
          assert_equal ObjectSpace.memsize_of(locks.class.new), ObjectSpace.memsize_of(locks)
        end
      end

      def return_from_lock(locks)
        locks.synchronize(:key) { return :returned }
      end
    end
  end
end
