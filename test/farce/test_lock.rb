# frozen_string_literal: true

require_relative "../setup"

module Farce
  class TestLock < Test
    def teardown
      Fiber.set_scheduler(nil) if Fiber.respond_to?(:scheduler) && Fiber.scheduler
    end

    def test_interface
      assert_empty Mutex.public_instance_methods(false) - Lock.public_instance_methods
    end

    def test_is_shareable_on_cruby
      return unless Internal.native_ractors?

      lock = Lock.new

      assert_predicate lock, :frozen?
      assert_predicate lock, :ractor_shareable?
      assert Ractor.shareable?(lock)
    end

    def test_frozen_uninitialized_lock_cannot_be_initialized
      return unless Internal.native_ractors?

      lock = Lock.allocate
      lock.freeze

      assert Ractor.shareable?(lock)
      assert_raises(FrozenError) { lock.send(:initialize) }
      assert_raises(RuntimeError) { lock.lock }
    end

    def test_lock_try_lock_unlock_and_state
      lock = Lock.new

      refute_predicate lock, :locked?
      refute_predicate lock, :owned?
      assert_same lock, lock.lock
      assert_predicate lock, :locked?
      assert_predicate lock, :owned?
      refute lock.try_lock
      assert_same lock, lock.unlock
      refute_predicate lock, :locked?
      assert lock.try_lock
      assert_predicate lock, :owned?
      lock.unlock
    end

    def test_recursive_locking_and_invalid_unlocks
      lock = Lock.new

      assert_raises(ThreadError) { lock.unlock }
      lock.lock
      assert_raises(ThreadError) { lock.lock }

      error = Thread.new do
        assert_predicate lock, :locked?
        refute_predicate lock, :owned?
        assert_raises(ThreadError) { lock.unlock }
      end.value

      assert_instance_of ThreadError, error
      lock.unlock
    end

    def test_synchronize_requires_a_block_and_returns_its_result
      lock = Lock.new
      native_error = assert_raises(StandardError) { Mutex.new.synchronize }

      assert_raises(native_error.class) { lock.synchronize }
      assert_equal(:result, lock.synchronize { :result })
      assert_raises(RuntimeError) { lock.synchronize { raise "failed" } }
      assert lock.try_lock
      lock.unlock
    end

    def test_concurrent_threads_are_serialized
      lock = Lock.new
      value = 0
      workers = 8.times.map do
        Thread.new do
          250.times do
            lock.synchronize do
              current = value
              Thread.pass
              value = current + 1
            end
          end
        end
      end
      workers.each(&:join)

      assert_equal 2_000, value
    ensure
      workers&.each { it.kill.join }
    end

    def test_ownership_is_fiber_local
      lock = Lock.new
      lock.lock
      observations = Fiber.new do
        [lock.locked?, lock.owned?, lock.try_lock, assert_raises(ThreadError) { lock.unlock }]
      end.resume

      assert_equal [true, false, false], observations.first(3)
      assert_instance_of ThreadError, observations.last
      assert_predicate lock, :owned?
      lock.unlock
    end

    def test_unscheduled_fiber_on_the_owner_thread_raises_instead_of_deadlocking
      lock = Lock.new

      error = assert_raises(ThreadError) do
        lock.synchronize do
          Fiber.new { lock.lock }.resume
        end
      end

      assert_match(/another fiber.*same thread/, error.message)
      assert_equal(:available, lock.synchronize { :available })
    end

    def test_truffle_deadlock_check_bypasses_an_overridden_thread_equal
      return unless RUBY_ENGINE == "truffleruby" && TruffleRuby.native?

      lock = Lock.new
      thread = Thread.current
      singleton = thread.singleton_class
      thread.define_singleton_method(:equal?) { |_other| false }

      error = Timeout.timeout(2) do
        assert_raises(ThreadError) do
          lock.synchronize { Fiber.new { lock.lock }.resume }
        end
      end

      assert_match(/another fiber.*same thread/, error.message)
      assert_equal(:available, lock.synchronize { :available })
    ensure
      singleton&.send(:remove_method, :equal?)
    end

    def test_sleep_releases_and_reacquires_the_lock
      lock = Lock.new
      acquired = ::Queue.new
      lock.lock
      worker = Thread.new { lock.synchronize { acquired << true } }
      native = Mutex.new
      native_sleep_result = native.synchronize { native.sleep(0) }

      sleep_result = lock.sleep(0.02)
      native_sleep_result.nil? ? assert_nil(sleep_result) : assert_equal(native_sleep_result, sleep_result)

      assert acquired.pop
      assert_predicate lock, :owned?
      lock.unlock
      worker.join
    ensure
      lock&.unlock if lock&.owned?
      worker&.kill&.join
    end

    def test_interrupted_sleep_reacquires_before_propagating
      return unless Internal.native_ractors?

      lock = Lock.new
      sleeping = ::Queue.new
      holding = ::Queue.new
      release_holder = ::Queue.new
      errors = ::Queue.new
      sleeper = Thread.new do
        lock.synchronize do
          sleeping << true
          lock.sleep
        end
      rescue RuntimeError => e
        errors << e
      end
      sleeping.pop
      holder = Thread.new do
        lock.synchronize do
          holding << true
          release_holder.pop
        end
      end
      holding.pop

      sleeper.raise "interrupt sleep"
      sleep 0.01

      assert_predicate sleeper, :alive?, "sleep returned before the lock was reacquired"
      release_holder << true
      sleeper.join
      holder.join

      assert_equal "interrupt sleep", errors.pop.message
      assert_equal(:available, lock.synchronize { :available })
    ensure
      release_holder << true if release_holder
      sleeper&.kill&.join
      holder&.kill&.join
    end

    def test_waiting_thread_can_be_interrupted_without_poisoning_the_lock
      return unless Internal.native_ractors?

      lock = Lock.new
      errors = ::Queue.new
      lock.lock
      waiter = Thread.new do
        lock.synchronize { flunk "interrupted waiter acquired the lock" }
      rescue RuntimeError => e
        errors << e
      end
      wait_until_blocked(waiter)

      waiter.raise "interrupt waiter"

      waiter.join

      assert_equal "interrupt waiter", errors.pop.message
      lock.unlock

      assert_equal(:available, lock.synchronize { :available })
    ensure
      lock&.unlock if lock&.owned?
      waiter&.kill&.join
    end

    def test_truffle_direct_lock_wait_can_be_interrupted_while_owner_holds
      return unless RUBY_ENGINE == "truffleruby"

      lock = Lock.new
      ready = ::Queue.new
      lock.lock
      waiter = Thread.new do
        ready << true
        lock.lock

        flunk "interrupted waiter acquired the lock"
      rescue RuntimeError => e
        e
      end
      Timeout.timeout(5) { ready.pop }
      wait_until_blocked(waiter)

      waiter.raise "interrupt direct lock wait"

      assert waiter.join(5), "direct lock waiter ignored Thread#raise"
      assert_equal "interrupt direct lock wait", waiter.value.message
      assert_predicate lock, :owned?, "the original owner must retain the lock"
      lock.unlock

      assert_equal(:available, lock.synchronize { :available })
    ensure
      lock&.unlock if lock&.owned?
      waiter&.kill&.join
    end

    def test_interruption_while_recording_owner_does_not_poison_the_native_mutex
      return unless RUBY_ENGINE == "truffleruby"

      %i[lock try_lock synchronize].each do |operation|
        lock = Lock.new
        owner = lock.instance_variable_get(:@farce_owner_thread)
        original_set = owner.method(:set)
        entered = ::Queue.new
        release = ::Queue.new
        start = ::Queue.new
        worker = nil
        injected = false
        owner.define_singleton_method(:set) do |value|
          if value && Thread.current.equal?(worker) && !injected
            injected = true
            entered << true
            release.pop
            Thread.pass until Thread.pending_interrupt?
          end
          original_set.call(value)
        end
        worker = Thread.new do
          start.pop
          operation == :synchronize ? lock.synchronize { flunk } : lock.public_send(operation)
        rescue RuntimeError => e
          e
        end
        start << true
        Timeout.timeout(5) { entered.pop }

        worker.raise "interrupt #{operation} owner recording"
        release << true

        assert worker.join(5), "#{operation} interruption did not unwind"
        assert_equal "interrupt #{operation} owner recording", worker.value.message
        assert_equal(:available, lock.synchronize { :available })
      ensure
        start << true if start
        release << true if release
        worker&.kill&.join
        lock&.unlock if lock&.owned?
      end
    end

    def test_canceling_one_of_multiple_waiters_does_not_strand_the_others
      return unless Internal.native_ractors?

      lock = Lock.new
      ready = ::Queue.new
      acquired = ::Queue.new
      errors = ::Queue.new
      lock.lock
      waiters = 3.times.map do |index|
        Thread.new do
          ready << true
          lock.synchronize { acquired << index }
        rescue RuntimeError => e
          errors << e
        end
      end
      3.times { ready.pop }
      waiters.each { wait_until_blocked(it) }

      waiters[1].raise "cancel waiter"

      waiters[1].join

      assert_equal "cancel waiter", errors.pop.message
      lock.unlock
      waiters.values_at(0, 2).each(&:join)

      assert_equal [0, 2], 2.times.map { acquired.pop }.sort
      assert_equal(:available, lock.synchronize { :available })
    ensure
      lock&.unlock if lock&.owned?
      waiters&.each { it.kill.join }
    end

    def test_coordinates_native_ractors
      return unless Internal.native_ractors?

      lock = Lock.new
      events = Port.new
      lock.lock
      worker = Ractor.new(lock, events) do |shared, port|
        port << :waiting
        shared.synchronize { port << :acquired }
        :done
      end

      assert_equal :waiting, events.receive
      result = ::Queue.new
      receiver = Thread.new { result << events.receive }

      sleep 0.01

      assert_predicate result, :empty?
      lock.unlock

      assert_equal :acquired, result.pop
      assert_equal :done, ractor_value(worker)
      receiver.join
    ensure
      lock&.unlock if lock&.owned?
      receiver&.kill&.join
    end

    def test_waiting_does_not_block_a_fiber_scheduler
      return unless Internal.native_ractors?
      skip "Fiber schedulers are not supported" unless Fiber.respond_to?(:set_scheduler)

      scheduler = Helpers::QueueTestScheduler.new
      Fiber.set_scheduler(scheduler)
      lock = Lock.new
      events = []

      Fiber.schedule do
        lock.synchronize do
          events << :locked
          Fiber.scheduler.kernel_sleep(0.01)
          events << :releasing
        end
      end
      Fiber.schedule do
        events << :waiting
        lock.synchronize { events << :acquired }
      end
      Fiber.set_scheduler(nil)

      assert_equal %i[locked waiting releasing acquired], events
      assert_operator scheduler.io_wait_calls, :>=, 1
    end

    private

    def ractor_value(ractor) = ractor.respond_to?(:value) ? ractor.value : ractor.take

    def wait_until_blocked(thread)
      deadline = Clock.timeout(1)
      Thread.pass until thread.status == "sleep" || Clock.now >= deadline

      assert_equal "sleep", thread.status, "thread did not block while waiting for the lock"
    end
  end
end
