# frozen_string_literal: true

require_relative "../../setup"

module Farce
  class TestAtom < Test
    include Helpers::InternalTestHelpers

    Atom = Internal::Atom

    def run(...) = Timeout.timeout(0.5) { super }

    def test_default_and_shareability
      atom = Atom.new

      assert_nil atom.value
      refute_predicate atom, :compare_by_identity?
      assert Ractor.shareable?(atom) if Internal.native_ractors?
    end

    def test_initialization_validation
      assert_raises(Ractor::IsolationError) { Atom.new(Object.new) } if Internal.native_ractors?
      assert_raises(ArgumentError) { Atom.new(compare_by_identity: nil) }
    end

    def test_value_writer
      atom = Atom.new(1)

      assert_equal 2, atom.value = 2
      assert_equal 2, atom.value
      assert_raises(Ractor::IsolationError) { atom.value = [] } if Internal.native_ractors?

      assert_equal 2, atom.value
    end

    def test_get_and_store
      atom = Atom.new(1)

      assert_equal 1, atom.get
      assert_equal 2, atom.store(2)
      assert_equal 2, atom.get(timeout: 0)
      assert_raises(Ractor::IsolationError) { atom.store([]) } if Internal.native_ractors?

      assert_equal 2, atom.value
    end

    def test_get_and_store_can_time_out_while_an_update_is_in_flight
      atom = Atom.new(1)
      entered = Thread::Queue.new
      release = Thread::Queue.new
      updater = Thread.new do
        atom.upsert(0) do |old|
          entered << true
          release.pop
          old + 1
        end
      end
      entered.pop

      assert_equal :get_timeout, atom.get(timeout: 0) { :get_timeout }
      assert_equal :store_timeout, atom.store(3, timeout: 0) { :store_timeout }
      store_if_absent_called = false
      upsert_called = false

      assert_nil atom.store_if_absent(timeout: 0) { store_if_absent_called = true }
      refute atom.compare_and_set(1, 3, timeout: 0)
      assert_nil atom.upsert(0, timeout: 0) { upsert_called = true }
      refute store_if_absent_called
      refute upsert_called
      assert_equal 1, atom.value
    ensure
      release&.push(true)
      updater&.join
    end

    def test_timeout_validation
      atom = Atom.new

      assert_raises(ArgumentError) { atom.get(timeout: -1) }
      assert_raises(ArgumentError) { atom.store(1, timeout: Float::INFINITY) }
      assert_raises(ArgumentError) { atom.swap(1, timeout: -0.1) }
      assert_raises(ArgumentError) { atom.store_if_absent(timeout: -1) { 1 } }
      assert_raises(ArgumentError) { atom.compare_and_set(nil, 1, timeout: -1) }
      assert_raises(ArgumentError) { atom.update(timeout: -1) { nil } }
      assert_raises(ArgumentError) { atom.upsert(1, timeout: -1) { 2 } }
      assert_raises(ArgumentError) { atom.wait_until_changed(nil, timeout: -1) }
      assert_raises(ArgumentError) { atom.wait_until_non_nil(timeout: Float::NAN) }
    end

    def test_swap
      atom = Atom.new(1)

      assert_equal 1, atom.swap(2)
      assert_equal 2, atom.value
      assert_raises(Ractor::IsolationError) { atom.swap([]) } if Internal.native_ractors?

      assert_equal 2, atom.value
    end

    def test_store_if_absent
      atom = Atom.new
      calls = 0

      assert_equal 10, atom.store_if_absent(timeout: 0) {
        calls += 1
        10
      }
      assert_equal(10, atom.store_if_absent do
        calls += 1
        20
      end)
      assert_equal 1, calls
    end

    def test_store_if_absent_executes_once_under_contention
      atom = Atom.new
      calls = 0
      calls_lock = Mutex.new
      threads = 8.times.map do
        Thread.new do
          atom.store_if_absent do
            calls_lock.synchronize { calls += 1 }
            sleep 0.01
            42
          end
        end
      end

      assert_equal [42], threads.map(&:value).uniq
      assert_equal 1, calls
    end

    def test_failed_store_does_not_poison_the_atom
      atom = Atom.new

      assert_raises(RuntimeError) { atom.store_if_absent { raise "boom" } }
      assert_equal(7, atom.store_if_absent { 7 })
    end

    def test_compare_and_set_by_value
      original = shared_string("value")
      equal = shared_string("value")
      atom = Atom.new(original)

      assert atom.compare_and_set(equal, :replacement, timeout: 0)
      assert_equal :replacement, atom.value
      refute atom.compare_and_set(:other, :nope)
    end

    def test_compare_and_set_by_identity
      original = shared_string("value")
      equal = shared_string("value")
      atom = Atom.new(original, compare_by_identity: true)

      refute atom.compare_and_set(equal, :nope)
      assert atom.compare_and_set(original, :replacement)
      assert_predicate atom, :compare_by_identity?
    end

    def test_upsert
      atom = Atom.new
      called = false

      assert_equal 3, atom.upsert(3, timeout: 0) { called = true }
      refute called
      assert_equal 4, atom.upsert(0) { |old| old + 1 }
      assert_equal 4, atom.value
    end

    def test_update_always_calls_the_block_including_for_nil
      atom = Atom.new
      calls = 0

      assert_equal(1, atom.update do |old|
        calls += 1
        old.nil? ? 1 : old + 1
      end)
      assert_equal(2, atom.update do |old|
        calls += 1
        old + 1
      end)
      assert_equal 2, atom.value
      assert_equal 2, calls
    end

    def test_update_is_serialized_under_contention
      atom = Atom.new(0)
      threads = 8.times.map do
        Thread.new do
          atom.update do |old|
            Thread.pass
            old + 1
          end
        end
      end

      threads.each(&:join)

      assert_equal 8, atom.value
    end

    def test_update_timeout_does_not_invoke_the_block
      atom = Atom.new(1)
      entered = Thread::Queue.new
      release = Thread::Queue.new
      updater = Thread.new do
        atom.update do |old|
          entered << true
          release.pop
          old + 1
        end
      end
      entered.pop
      called = false

      assert_nil atom.update(timeout: 0) { called = true }
      refute called
      assert_equal 1, atom.value
    ensure
      release&.push(true)
      updater&.join
    end

    def test_update_with_timeout_succeeds_when_the_reservation_is_available
      atom = Atom.new(1)

      assert_equal 2, atom.update(timeout: 0) { |old| old + 1 }
      assert_equal 2, atom.value
    end

    def test_failed_update_recovers_and_does_not_notify_a_value_change
      atom = Atom.new

      assert_raises(Ractor::IsolationError) { atom.update { [] } } if Internal.native_ractors?

      assert_nil atom.value
      assert_equal :timeout,
        atom.wait_until_changed(nil, timeout: 0) { :timeout }
      assert_equal(:value, atom.update { :value })
      assert_equal :value, atom.wait_until_non_nil(timeout: 0)
    end

    def test_recursive_update_access_raises_and_releases_the_reservation
      atom = Atom.new(1)

      error = assert_raises(ThreadError) do
        atom.update { atom.store(9) }
      end

      assert_match(/recursive atom access during an update/, error.message)
      assert_equal 1, atom.value
      assert_equal(2, atom.update { |old| old + 1 })
    end

    def test_unscheduled_sibling_fiber_cannot_wait_for_the_owners_update
      atom = Atom.new(1)
      owner_thread = Thread.current
      contender = Fiber.new do
        next :different_thread unless Thread.current.equal?(owner_thread)

        atom.store(9)
      rescue ThreadError => e
        e
      end
      error = nil

      assert_equal(2, atom.update do |old|
        error = contender.resume
        old + 1
      end)
      if error == :different_thread
        assert_equal 2, atom.value
        assert_equal 3, atom.store(3)
        return
      end

      assert_kind_of ThreadError, error
      assert_match(/another unscheduled fiber/, error.message)
      assert_equal 2, atom.value
      assert_equal 3, atom.store(3)
    end

    def test_upsert_rejects_an_unshareable_block_result_and_recovers
      atom = Atom.new(1)

      assert_raises(Ractor::IsolationError) { atom.upsert(0) { [] } } if Internal.native_ractors?

      assert_equal 2, atom.upsert(0) { |old| old + 1 }
    end

    def test_wait_until_changed_returns_immediately_when_already_changed
      atom = Atom.new(:current)

      assert_equal :current, atom.wait_until_changed(:expected, timeout: 0)
    end

    def test_wait_until_changed_waits_for_a_new_value
      atom = Atom.new(:old)
      waiter = Thread.new { atom.wait_until_changed(:old, timeout: 1) }

      atom.value = :new

      assert_equal :new, waiter.value
    end

    def test_wait_until_changed_uses_value_equality_by_default
      original = shared_string("value")
      equal = shared_string("value")
      atom = Atom.new(original)

      assert_equal :timeout, atom.wait_until_changed(equal, timeout: 0) { :timeout }
    end

    def test_wait_until_changed_can_compare_by_identity
      original = shared_string("value")
      equal = shared_string("value")
      atom = Atom.new(original, compare_by_identity: true)

      assert_same original, atom.wait_until_changed(equal, timeout: 0)
      assert_nil atom.wait_until_changed(original, timeout: 0)
    end

    def test_wait_until_changed_wakes_all_waiters
      atom = Atom.new(:old)
      ready = Thread::Queue.new
      waiters = 4.times.map do
        Thread.new do
          ready << true
          atom.wait_until_changed(:old, timeout: 1)
        end
      end
      4.times { ready.pop }

      atom.store(:new)

      assert_equal [:new], waiters.map(&:value).uniq
    end

    def test_wait_until_non_nil
      atom = Atom.new
      waiter = Thread.new { atom.wait_until_non_nil(timeout: 1) }

      atom.store(false)

      refute waiter.value
      refute atom.wait_until_non_nil(timeout: 0)
    end

    def test_wait_timeouts_return_nil_or_call_a_fallback_block
      atom = Atom.new

      assert_nil atom.wait_until_changed(nil, timeout: 0)
      assert_equal :changed_timeout,
        atom.wait_until_changed(nil, timeout: 0) { :changed_timeout }
      assert_nil atom.wait_until_non_nil(timeout: 0)
      assert_equal :non_nil_timeout,
        atom.wait_until_non_nil(timeout: 0) { :non_nil_timeout }
    end

    def test_wait_does_not_block_a_fiber_scheduler
      return unless RUBY_ENGINE == "ruby"
      scheduler = Helpers::QueueTestScheduler.new
      Fiber.set_scheduler(scheduler)
      atom = Atom.new
      events = []

      Fiber.schedule do
        events << :wait_started
        events << atom.wait_until_non_nil
      end
      Fiber.schedule do
        events << :store_started
        atom.store(:value)
      end
      Fiber.set_scheduler(nil)

      assert_equal %i[wait_started store_started value], events
      assert_operator scheduler.io_wait_calls, :>=, 1
    ensure
      Fiber.set_scheduler(nil) if scheduler && Fiber.scheduler
    end

    def test_value_setter_contention_does_not_block_a_fiber_scheduler
      return unless RUBY_ENGINE == "ruby"

      scheduler = Helpers::QueueTestScheduler.new
      Fiber.set_scheduler(scheduler)
      atom = Atom.new(1)
      events = []

      Fiber.schedule do
        events << :updating
        atom.update do |old|
          Fiber.scheduler.kernel_sleep(0.01)
          events << :update_finished
          old + 1
        end
      end
      Fiber.schedule do
        events << :store_waiting
        atom.value = 3
        events << :stored
      end
      Fiber.set_scheduler(nil)

      assert_equal %i[updating store_waiting update_finished stored], events
      assert_equal 3, atom.value
      assert_operator scheduler.io_wait_calls, :>=, 1
    ensure
      Fiber.set_scheduler(nil) if scheduler && Fiber.scheduler
    end
  end
end
