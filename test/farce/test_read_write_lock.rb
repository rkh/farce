# frozen_string_literal: true

require_relative "../setup"

module Farce
  class TestReadWriteLock < Test
    def test_is_shareable
      lock = ReadWriteLock.new

      assert_predicate lock, :frozen?
      assert_predicate lock, :ractor_shareable?
      assert Ractor.shareable?(lock) if Internal.native_ractors?
    end

    def test_requires_blocks_and_returns_block_results
      lock = ReadWriteLock.new

      assert_raises(LocalJumpError) { lock.with_read_lock }
      assert_raises(LocalJumpError) { lock.with_write_lock }
      assert_equal(:read, lock.with_read_lock { :read })
      assert_equal(:write, lock.with_write_lock { :write })
    end

    def test_multiple_readers_can_enter_together
      lock = ReadWriteLock.new
      entered = Queue.new
      release = Queue.new
      readers = 2.times.map do
        Thread.new do
          lock.with_read_lock do
            entered << true
            release.pop
          end
        end
      end

      2.times { entered.pop }
      2.times { release << true }
      readers.each(&:join)
    ensure
      2.times { release << true } if release
      readers&.each { it.kill.join }
    end

    def test_writer_waits_for_readers
      lock = ReadWriteLock.new
      reader_entered = Queue.new
      release_reader = Queue.new
      writer_entered = Queue.new
      reader = Thread.new do
        lock.with_read_lock do
          reader_entered << true
          release_reader.pop
        end
      end
      reader_entered.pop
      writer = Thread.new { lock.with_write_lock { writer_entered << true } }

      sleep 0.01

      assert_predicate writer_entered, :empty?
      release_reader << true

      assert writer_entered.pop
      reader.join
      writer.join
    ensure
      release_reader << true if release_reader
      reader&.kill&.join
      writer&.kill&.join
    end

    def test_readers_wait_for_a_writer
      lock = ReadWriteLock.new
      writer_entered = Queue.new
      release_writer = Queue.new
      reader_entered = Queue.new
      writer = Thread.new do
        lock.with_write_lock do
          writer_entered << true
          release_writer.pop
        end
      end
      writer_entered.pop
      reader = Thread.new { lock.with_read_lock { reader_entered << true } }

      sleep 0.01

      assert_predicate reader_entered, :empty?
      release_writer << true

      assert reader_entered.pop
      writer.join
      reader.join
    ensure
      release_writer << true if release_writer
      writer&.kill&.join
      reader&.kill&.join
    end

    def test_locks_are_reentrant_and_read_locks_can_be_upgraded
      lock = ReadWriteLock.new
      events = []

      lock.with_read_lock do
        events << :read
        lock.with_read_lock { events << :read_again }
        lock.with_write_lock do
          events << :upgraded
          lock.with_write_lock { events << :write_again }
          lock.with_read_lock { events << :read_under_write }
        end
        events << :downgraded
      end

      assert_equal %i[read read_again upgraded write_again read_under_write downgraded], events
    end

    def test_competing_upgrades_do_not_deadlock
      lock = ReadWriteLock.new
      ready = Queue.new
      start = Queue.new
      writes = Queue.new
      workers = 2.times.map do |index|
        Thread.new do
          lock.with_read_lock do
            ready << true
            start.pop
            lock.with_write_lock { writes << index }
          end
        end
      end
      2.times { ready.pop }
      2.times { start << true }

      workers.each { assert it.join(2), "concurrent lock upgrade deadlocked" }

      assert_equal [0, 1], 2.times.map { writes.pop }.sort
    ensure
      2.times { start << true } if start
      workers&.each { it.kill.join }
    end

    def test_concurrent_writers_are_serialized
      lock = ReadWriteLock.new
      value = 0
      writers = 8.times.map do
        Thread.new do
          250.times do
            lock.with_write_lock do
              current = value
              Thread.pass
              value = current + 1
            end
          end
        end
      end
      writers.each(&:join)

      assert_equal 2_000, value
    ensure
      writers&.each { it.kill.join }
    end

    def test_upgrade_downgrades_to_the_outer_read_lock
      lock = ReadWriteLock.new
      downgraded = Queue.new
      release_reader = Queue.new
      writer_entered = Queue.new
      reader = Thread.new do
        lock.with_read_lock do
          lock.with_write_lock { nil }
          downgraded << true
          release_reader.pop
        end
      end
      downgraded.pop
      writer = Thread.new { lock.with_write_lock { writer_entered << true } }

      sleep 0.01

      assert_predicate writer_entered, :empty?
      release_reader << true

      assert writer_entered.pop
      reader.join
      writer.join
    ensure
      release_reader << true if release_reader
      reader&.kill&.join
      writer&.kill&.join
    end

    def test_exceptions_release_locks
      lock = ReadWriteLock.new

      assert_raises(RuntimeError) { lock.with_read_lock { raise "read failed" } }
      assert_equal(:write, lock.with_write_lock { :write })
      assert_raises(RuntimeError) { lock.with_write_lock { raise "write failed" } }
      assert_equal(:read, lock.with_read_lock { :read })
      assert_raises(RuntimeError) do
        lock.with_read_lock { lock.with_write_lock { raise "upgrade failed" } }
      end
      assert_equal(:available, lock.with_write_lock { :available })
    end

    def test_canceling_a_waiting_writer_does_not_poison_the_lock
      return if RUBY_ENGINE == "jruby"

      lock = ReadWriteLock.new
      reader_entered = Queue.new
      release_reader = Queue.new
      reader = Thread.new do
        lock.with_read_lock do
          reader_entered << true
          release_reader.pop
        end
      end
      reader_entered.pop
      writer = Thread.new { lock.with_write_lock { flunk "canceled writer acquired the lock" } }
      writer.report_on_exception = false
      wait_until_blocked(writer)

      writer.raise "cancel writer"

      assert_raises(RuntimeError) { writer.value }
      release_reader << true
      reader.join

      assert_equal(:available, lock.with_write_lock { :available })
    ensure
      release_reader << true if release_reader
      reader&.kill&.join
      stop_thread(writer)
    end

    def test_canceling_the_retained_upgrader_does_not_poison_the_lock
      return if RUBY_ENGINE == "jruby"

      lock = ReadWriteLock.new
      blocker_entered = Queue.new
      release_blocker = Queue.new
      blocker = Thread.new do
        lock.with_read_lock do
          blocker_entered << true
          release_blocker.pop
        end
      end
      blocker_entered.pop
      upgrader = Thread.new do
        lock.with_read_lock { lock.with_write_lock { flunk "canceled upgrader acquired the lock" } }
      end
      upgrader.report_on_exception = false
      wait_until_blocked(upgrader)

      upgrader.raise "cancel upgrader"

      assert_raises(RuntimeError) { upgrader.value }
      release_blocker << true
      blocker.join

      assert_equal(:available, lock.with_write_lock { :available })
    ensure
      release_blocker << true if release_blocker
      blocker&.kill&.join
      stop_thread(upgrader)
    end

    def test_canceling_a_released_upgrader_restores_its_read_lock
      return if RUBY_ENGINE == "jruby"

      lock = ReadWriteLock.new
      ready = Queue.new
      start_first = Queue.new
      start_second = Queue.new
      first_writing = Queue.new
      release_first = Queue.new
      second_restored = Queue.new
      release_second = Queue.new
      writer_entered = Queue.new
      first = Thread.new do
        lock.with_read_lock do
          ready << true
          start_first.pop
          lock.with_write_lock do
            first_writing << true
            release_first.pop
          end
        end
      end
      second = Thread.new do
        lock.with_read_lock do
          ready << true
          start_second.pop
          begin
            lock.with_write_lock { flunk "canceled upgrader acquired the lock" }
          rescue RuntimeError => e
            second_restored << true
            release_second.pop
            raise e
          end
        end
      end
      second.report_on_exception = false
      2.times { ready.pop }
      start_first << true
      wait_until_upgrader_registered(lock)
      start_second << true
      first_writing.pop

      second.raise "cancel second upgrader"
      release_first << true

      first.join
      second_restored.pop
      writer = Thread.new { lock.with_write_lock { writer_entered << true } }

      sleep 0.01

      assert_predicate writer_entered, :empty?
      release_second << true
      assert_raises(RuntimeError) { second.value }
      assert writer_entered.pop
      writer.join
    ensure
      start_first << true if start_first
      start_second << true if start_second
      release_first << true if release_first
      release_second << true if release_second
      stop_thread(first)
      stop_thread(second)
      stop_thread(writer)
    end

    def test_coordinates_native_ractors
      return unless Internal.native_ractors?

      lock = ReadWriteLock.new
      events = Port.new
      reader = Ractor.new(lock, events) do |shared, port|
        shared.with_read_lock do
          port << :reading
          Ractor.receive
        end
        :reader_done
      end

      assert_equal :reading, events.receive
      writer = Ractor.new(lock, events) do |shared, port|
        port << :attempting
        shared.with_write_lock { port << :writing }
        :writer_done
      end

      assert_equal :attempting, events.receive
      results = Queue.new
      collector = Thread.new { results << events.receive }

      sleep 0.01

      assert_predicate results, :empty?
      reader.send(:release)

      assert_equal :reader_done, ractor_value(reader)
      assert_equal :writing, results.pop
      assert_equal :writer_done, ractor_value(writer)
      collector.join
    ensure
      release_ractor(reader)
      collector&.kill&.join
    end

    private

    def release_ractor(ractor)
      ractor&.send(:release)
    rescue Ractor::ClosedError
      nil
    end

    def ractor_value(ractor) = ractor.respond_to?(:value) ? ractor.value : ractor.take

    def wait_until_upgrader_registered(lock)
      state = lock.instance_variable_get(:@state)
      upgrader_bit = ReadWriteLock.const_get(:UPGRADER_BIT, false)
      deadline = Clock.timeout(1)
      Thread.pass until state[0].anybits?(upgrader_bit) || Clock.now >= deadline

      assert state[0].anybits?(upgrader_bit), "upgrader did not register while waiting for the lock"
    end

    def wait_until_blocked(thread)
      deadline = Clock.timeout(1)
      Thread.pass until thread.status == "sleep" || Clock.now >= deadline

      assert_equal "sleep", thread.status, "thread did not block while waiting for the lock"
    end

    def stop_thread(thread)
      return unless thread&.alive?
      thread.kill
      thread.join
    end
  end

  class TestReadWriteLockFiberScheduler < Test
    def setup
      skip "Fiber schedulers are not supported on TruffleRuby" if RUBY_ENGINE == "truffleruby"
      skip "Fiber schedulers are not supported" unless Fiber.respond_to?(:set_scheduler)
    end

    def teardown
      Fiber.set_scheduler(nil) if Fiber.respond_to?(:scheduler) && Fiber.scheduler
    end

    def test_waiting_for_a_write_lock_does_not_block_the_scheduler
      scheduler = Helpers::QueueTestScheduler.new
      Fiber.set_scheduler(scheduler)
      lock = ReadWriteLock.new
      events = []

      Fiber.schedule do
        lock.with_read_lock do
          events << :reading
          Fiber.scheduler.kernel_sleep(0.01)
          events << :read_finished
        end
      end
      Fiber.schedule do
        events << :write_waiting
        lock.with_write_lock { events << :writing }
      end
      Fiber.set_scheduler(nil)

      assert_equal %i[reading write_waiting read_finished writing], events
      assert_operator scheduler.io_wait_calls, :>=, 1
    end
  end
end
