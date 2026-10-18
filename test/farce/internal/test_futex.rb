# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

return unless RUBY_ENGINE == "ruby"

require_relative "../../setup"
require "timeout"

module Farce
  module Internal
    module FutexTestHelpers
      include Helpers::InternalTestHelpers

      def wait_for_registration(signal, count)
        Timeout.timeout(5) { Thread.pass until signal.num_waiting == count }
      end

      def require_native_futex
        available = Internal.send(:futex_supported?)
        assert available, "the required native futex capability is unavailable" if ENV["REQUIRE_FUTEX"] == "1"
        skip "native futex is unavailable" unless available
      end

      def require_ring_futex
        require_native_futex
        @scheduler = FiberScheduler.new(backend: :io_uring)
        available = @scheduler.send(:futex_supported?)
        assert available, "the required io_uring futex opcode is unavailable" if ENV["REQUIRE_FUTEX"] == "1"
        skip "io_uring futex is unavailable" unless available
        Fiber.set_scheduler(@scheduler)
      rescue ArgumentError, SystemCallError => e
        flunk "the required io_uring backend is unavailable: #{e}" if ENV["REQUIRE_FUTEX"] == "1"
        skip "io_uring is unavailable: #{e}"
      end

      def assert_resource_probe(method)
        unless open_file_descriptor_count
          flunk "required descriptor counts are unavailable" if ENV["REQUIRE_FUTEX"]
          skip "descriptor counts are unavailable"
        end

        source = <<~RUBY
          ARGV.replace(["--name", "#{self.class.name}##{method}"])
          require "farce/internal/test_futex"
        RUBY
        output, error, status = ruby_isolated(source, env: { "FARCE_FUTEX_RESOURCE_CHILD" => "1" })

        assert_predicate status, :success?, "#{error}\n#{output}"
        assert_match(/1 tests?, .*0 failures, 0 errors, 0 skips/, output)
      end

      def descriptor_count
        open_file_descriptor_count || flunk("descriptor counts are unavailable")
      end
    end

    class TestFutexFallbackThreads < Test
      include FutexTestHelpers

      def test_thread_waiters_preserve_descriptor_cleanup_after_cancellation
        unless ENV["FARCE_FUTEX_RESOURCE_CHILD"] == "1"
          assert_resource_probe(__method__)
          return
        end

        signal = Signal.new
        ready = Thread::Queue.new
        start = Thread::Queue.new
        waiters = 16.times.map do
          Thread.new do
            ready << true
            start.pop
            signal.wait
          rescue RuntimeError => e
            e.message
          end
        end
        waiters.size.times { ready.pop }
        before = descriptor_count
        waiters.size.times { start << true }
        wait_for_registration(signal, waiters.size)

        assert_equal before + (waiters.size * 2), descriptor_count

        waiters.first(8).each do |waiter|
          waiter.raise "cancel futex wait"

          assert waiter.join(5), "interrupted futex waiter did not unwind"
          assert_equal "cancel futex wait", waiter.value
        end
        assert_equal 8, signal.num_waiting
        assert_equal before + 16, descriptor_count
        signal.broadcast
        waiters.drop(8).each { assert_equal 1, it.value }

        assert_equal 0, signal.num_waiting
        assert_equal before, descriptor_count
      ensure
        signal&.broadcast
        waiters&.each { it.kill.join }
      end

      def test_mixed_thread_and_external_scheduler_waiters_keep_the_cooperative_path
        unless ENV["FARCE_FUTEX_RESOURCE_CHILD"] == "1"
          assert_resource_probe(__method__)
          return
        end

        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        signal = Signal.new
        ready = Thread::Queue.new
        start = Thread::Queue.new
        waiter = Thread.new do
          ready << true
          start.pop
          signal.wait
        end
        ready.pop
        before = descriptor_count
        start << true
        wait_for_registration(signal, 1)
        observed = []
        Fiber.schedule { observed << signal.wait }

        assert_equal 2, signal.num_waiting

        assert_equal before + 4, descriptor_count
        assert_equal 1, scheduler.io_wait_calls
        signal.broadcast
        Fiber.set_scheduler(nil)

        assert_equal [1], observed
        assert_equal 1, waiter.value
        assert_equal 0, signal.num_waiting
      ensure
        signal&.broadcast
        Fiber.set_scheduler(nil) if Fiber.scheduler
        waiter&.kill&.join
      end
    end

    class FutexTreeKey
      attr_reader :rank

      def initialize(rank)
        @rank = rank
        freeze
      end

      def <=>(other)
        if Fiber[:pause_tree_comparison]
          Fiber[:pause_tree_comparison] = false
          Fiber.scheduler.block(:tree_comparison)
        end
        rank <=> other.rank
      end
    end

    class TestFutexRing < Test
      include FutexTestHelpers

      def setup
        require_ring_futex
      end

      def teardown
        Fiber.set_scheduler(nil) if Fiber.scheduler
        @scheduler&.close unless @scheduler&.closed?
      end

      def test_many_waiters_work_below_the_pipe_descriptor_limit
        unless ENV["FARCE_FUTEX_RESOURCE_CHILD"] == "1"
          assert_resource_probe(__method__)
          return
        end

        signal = Signal.new
        before = descriptor_count
        _, maximum = Process.getrlimit(Process::RLIMIT_NOFILE)
        Process.setrlimit(Process::RLIMIT_NOFILE, before + 12, maximum)
        results = []
        waiters = 32.times.map { Fiber.schedule { results << signal.wait } }

        assert_equal waiters.size, signal.num_waiting
        assert_equal before, descriptor_count
        signal.broadcast
        @scheduler.run

        assert_equal [1] * waiters.size, results
        assert_equal 0, signal.num_waiting
        assert_equal before, descriptor_count
        reader, writer = IO.pipe
        writer.write("ok")
        writer.close

        assert_equal "ok", reader.read
        reader.close
      ensure
        signal&.broadcast
        reader&.close unless reader&.closed?
        writer&.close unless writer&.closed?
      end

      def test_broadcast_before_dispatch_uses_no_waiter_descriptors_and_survives_compaction
        unless ENV["FARCE_FUTEX_RESOURCE_CHILD"] == "1"
          assert_resource_probe(__method__)
          return
        end

        signal = Signal.new
        results = []
        before = descriptor_count
        waiters = 24.times.map { Fiber.schedule { results << signal.wait } }
        tokens = waiters.map { @scheduler.send(:current_wait, it) }

        assert_equal 24, signal.num_waiting
        assert_equal 24, tokens.uniq.size
        assert_equal before, descriptor_count
        GC.start
        GC.compact
        signal.broadcast
        @scheduler.run

        assert_equal [1] * waiters.size, results
        assert_equal 0, signal.num_waiting
        assert_equal 0, @scheduler.send(:pending_count)
        assert_equal before, descriptor_count
        assert_predicate @scheduler, :idle?
      ensure
        signal&.broadcast
      end

      def test_notification_and_cancellation_cannot_resume_a_reused_wait
        8.times do
          signals = Array.new(24) { Signal.new }
          results = []
          cancelled = 0
          tasks = signals.map do |signal|
            Fiber.schedule do
              begin
                signal.wait

                flunk "cancelled wait returned"
              rescue RuntimeError => e
                assert_equal "cancel pending futex", e.message
                cancelled += 1
              end
              results << signal.wait(timeout: 0.001)
            end
          end
          GC.start
          GC.compact
          tasks.each_with_index do |task, index|
            signals[index].broadcast if index.even?
            @scheduler.fiber_interrupt(task, RuntimeError.new("cancel pending futex"))
            signals[index].broadcast if index.odd?
          end
          @scheduler.run

          assert_equal tasks.size, cancelled
          assert_equal [nil] * tasks.size, results
          assert_equal [0], signals.map(&:num_waiting).uniq
          assert_equal 0, @scheduler.send(:pending_count)
          assert_predicate @scheduler, :idle?
        end
      end

      def test_cancellation_after_lock_notification_hands_ownership_to_the_next_waiter
        unless ENV["FARCE_FUTEX_RESOURCE_CHILD"] == "1"
          assert_resource_probe(__method__)
          return
        end

        before = descriptor_count
        lock = Lock.new
        lock.lock
        events = []
        first = Fiber.schedule do
          lock.synchronize { flunk "cancelled waiter acquired the lock" }
        rescue RuntimeError => e
          events << e.message
        end
        second = Fiber.schedule { lock.synchronize { events << :acquired } }

        assert_equal before, descriptor_count
        lock.unlock
        @scheduler.fiber_interrupt(first, RuntimeError.new("cancel notified waiter"))
        @scheduler.run

        assert_equal ["cancel notified waiter", :acquired], events
        refute_predicate first, :alive?
        refute_predicate second, :alive?
        refute_predicate lock, :locked?
        assert_equal 0, @scheduler.send(:pending_count)
      ensure
        lock&.unlock if lock&.owned?
      end

      def test_expanded_consumers_use_no_waiter_descriptors_and_accept_cross_ractor_notifications
        unless ENV["FARCE_FUTEX_RESOURCE_CHILD"] == "1"
          assert_resource_probe(__method__)
          return
        end

        atom = Atom.new
        map = Map.new
        vector = Vector.new
        queue = Farce::PriorityQueue.new
        operations = [
          -> { atom.wait_until_non_nil },
          -> { map.wait_until_non_nil(:value) },
          -> { vector.wait_until_non_nil(0) },
          -> { queue.pop }
        ]
        results = []
        cancelled = 0
        before = descriptor_count
        tasks = operations.flat_map do |operation|
          2.times.map do
            Fiber.schedule do
              results << operation.call
            rescue RuntimeError => e
              assert_equal "cancel consumer", e.message
              cancelled += 1
            end
          end
        end

        assert_equal tasks.size, @scheduler.send(:pending_count)
        assert_equal before, descriptor_count
        GC.start
        GC.compact
        tasks.each_slice(2) { |first, _| @scheduler.fiber_interrupt(first, RuntimeError.new("cancel consumer")) }
        producer = Ractor.new(atom, map, vector, queue) do |a, m, v, q|
          a.store(:ready)
          m.store(:value, :ready)
          v.store(0, :ready)
          q.push(:ready, priority: 0)
          :done
        end
        @scheduler.run

        assert_equal :done, ractor_value(producer)
        assert_equal 4, cancelled
        assert_equal [:ready] * operations.size, results
        assert_equal 0, queue.num_waiting
        assert_equal 0, @scheduler.send(:pending_count)
        assert_predicate @scheduler, :idle?
      ensure
        atom&.store(:ready)
        map&.store(:value, :ready)
        vector&.store(0, :ready)
        queue&.close
      end

      def test_tree_map_gate_handoff_uses_no_waiter_descriptors_and_survives_cancellation
        unless ENV["FARCE_FUTEX_RESOURCE_CHILD"] == "1"
          assert_resource_probe(__method__)
          return
        end

        map = ShareableTreeMap.new(FutexTreeKey.new(1) => :one)
        before = descriptor_count
        owner = Fiber.schedule do
          Fiber[:pause_tree_comparison] = true
          map[FutexTreeKey.new(2)] = :two
        end
        cancelled = nil
        waiter = Fiber.schedule do
          map[FutexTreeKey.new(3)] = :three
        rescue RuntimeError => e
          cancelled = e.message
        end
        last = Fiber.schedule { map[FutexTreeKey.new(4)] = :four }

        assert_equal 3, @scheduler.send(:pending_count)
        assert_equal before, descriptor_count
        @scheduler.fiber_interrupt(waiter, RuntimeError.new("cancel tree gate"))
        @scheduler.unblock(:tree_comparison, owner)
        @scheduler.run

        assert_equal "cancel tree gate", cancelled
        assert_equal([1, 2, 4], map.each.map { |key, _| key.rank })
        refute_predicate last, :alive?
        assert_equal 0, @scheduler.send(:pending_count)
      ensure
        @scheduler&.unblock(:tree_comparison, owner) if owner&.alive?
      end

      def test_priority_queue_gate_uses_no_waiter_descriptors_and_survives_cancellation
        unless ENV["FARCE_FUTEX_RESOURCE_CHILD"] == "1"
          assert_resource_probe(__method__)
          return
        end

        queue = PriorityQueue.new
        queue.push(FutexTreeKey.new(1), :one)
        before = descriptor_count
        owner = Fiber.schedule do
          Fiber[:pause_tree_comparison] = true
          queue.push(FutexTreeKey.new(2), :two)
        end
        cancelled = nil
        waiter = Fiber.schedule do
          queue.peek
        rescue RuntimeError => e
          cancelled = e.message
        end
        results = []
        last = Fiber.schedule { results << queue.peek }

        assert_equal 3, @scheduler.send(:pending_count)
        assert_equal before, descriptor_count
        @scheduler.fiber_interrupt(waiter, RuntimeError.new("cancel priority queue gate"))
        @scheduler.unblock(:tree_comparison, owner)
        @scheduler.run

        assert_equal "cancel priority queue gate", cancelled
        assert_equal [:one], results
        assert_equal 2, queue.size
        refute_predicate last, :alive?
        assert_equal 0, @scheduler.send(:pending_count)
      ensure
        @scheduler&.unblock(:tree_comparison, owner) if owner&.alive?
      end

      def test_one_signal_mixes_native_threads_and_ring_and_epoll_ractors
        signal = Signal.new
        ready = Farce::Queue.new
        workers = %i[io_uring epoll].map do |backend|
          Ractor.new(signal, ready, backend) do |shared, started, selected|
            scheduler = Farce.const_get(:Internal)::FiberScheduler.new(backend: selected)
            Fiber.set_scheduler(scheduler)
            results = []
            Fiber.schedule { results << shared.wait }
            started.push(scheduler.backend)
            scheduler.run
            Fiber.set_scheduler(nil)
            [selected, results]
          end
        end
        backends = Timeout.timeout(5) { workers.size.times.map { ready.pop }.sort }

        assert_equal %i[epoll io_uring], backends
        thread = Thread.new { signal.wait }
        wait_for_registration(signal, 3)

        assert_equal 1, signal.broadcast
        assert_equal [[:epoll, [1]], [:io_uring, [1]]], workers.map { ractor_value(it) }.sort
        assert_equal 1, thread.value
        assert_equal 0, signal.num_waiting
      ensure
        signal&.broadcast
        thread&.kill&.join
      end

      def test_setup_failure_after_submission_drains_the_original_request_before_reuse
        Fiber.set_scheduler(nil)
        scheduler_class = Class.new(FiberScheduler) do
          attr_accessor :fail_setup
          attr_reader :failed_token

          private

          def wait_with_timeout(token, ...)
            if fail_setup
              @failed_token = token
              raise "futex timer setup failed"
            end
            super
          end
        end
        @scheduler = scheduler_class.new(backend: :io_uring)
        @scheduler.fail_setup = true
        Fiber.set_scheduler(@scheduler)
        signal = Signal.new
        error = nil
        task = Fiber.schedule do
          signal.wait
        rescue RuntimeError => e
          error = e
        end

        assert_instance_of RuntimeError, error
        assert_equal "futex timer setup failed", error.message
        assert_equal 0, signal.num_waiting
        assert_equal 0, @scheduler.send(:pending_count)
        assert_nil @scheduler.send(:current_wait, task)
        assert_predicate @scheduler, :idle?
        @scheduler.fail_setup = false
        results = []
        Fiber.schedule { results << signal.wait(timeout: 0.001) }

        refute @scheduler.send(:resume_wait, @scheduler.failed_token, :stale)
        GC.compact
        @scheduler.run

        assert_equal [nil], results
        assert_equal 0, signal.num_waiting
        assert_equal 0, @scheduler.send(:pending_count)
      ensure
        signal&.broadcast
      end

      def test_root_exception_cancels_and_drains_pending_futex_storage
        signals = Array.new(16) { Signal.new }
        events = []
        signals.each do |signal|
          Fiber.schedule do
            signal.wait
          ensure
            events << :cleaned
          end
        end

        assert_raises(RuntimeError) do
          raise "stop scheduler"
        ensure
          Fiber.set_scheduler(nil)
        end

        assert_equal [:cleaned] * signals.size, events
        assert_equal [0], signals.map(&:num_waiting).uniq
        assert_equal 0, @scheduler.send(:pending_count)
        assert_predicate @scheduler, :closed?
        GC.compact
      end
    end

    class TestFutexFallback < Test
      include FutexTestHelpers

      def teardown
        Fiber.set_scheduler(nil) if Fiber.scheduler
      end

      def test_forced_fallback_build_disables_native_and_ring_capabilities
        if ENV["REQUIRE_FUTEX"] == "0"
          refute Internal.send(:futex_supported?)
          scheduler = FiberScheduler.new(backend: :io_uring)

          refute scheduler.send(:futex_supported?)
          scheduler.close
        else
          assert_includes [true, false], Internal.send(:futex_supported?)
        end
      end

      def test_unsupported_scheduler_uses_pipes_and_cleans_cancelled_waiters
        unless ENV["FARCE_FUTEX_RESOURCE_CHILD"] == "1"
          assert_resource_probe(__method__)
          return
        end

        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        signal = Signal.new
        before = descriptor_count
        result = []
        task = Fiber.schedule do
          signal.wait
        rescue RuntimeError => e
          result << e.message
        end

        assert_equal 1, signal.num_waiting
        assert_equal before + 2, descriptor_count
        assert_equal 1, scheduler.io_wait_calls
        scheduler.fiber_interrupt(task, RuntimeError.new("cancel fallback wait"))
        Fiber.set_scheduler(nil)

        assert_equal ["cancel fallback wait"], result
        assert_equal 0, signal.num_waiting
        assert_equal before - 2, descriptor_count
      ensure
        signal&.broadcast
      end

      def test_atom_descriptor_pressure_preserves_cooperative_producer_progress
        unless ENV["FARCE_FUTEX_RESOURCE_CHILD"] == "1"
          assert_resource_probe(__method__)
          return
        end

        assert Process.const_defined?(:RLIMIT_NOFILE), "descriptor limits are unavailable"

        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        atom = Atom.new
        resources = []
        _, maximum = Process.getrlimit(Process::RLIMIT_NOFILE)
        Process.setrlimit(Process::RLIMIT_NOFILE, descriptor_count + 16, maximum)
        begin
          loop { resources.concat(IO.pipe) }
        rescue Errno::EMFILE, Errno::ENFILE
          # Keep every allocated descriptor reachable throughout Atom's GC retry.
        end
        result = []
        Fiber.schedule { result << atom.wait_until_non_nil }
        Fiber.schedule { atom.store(:ready) }
        Fiber.set_scheduler(nil)

        assert_equal [:ready], result
        assert_operator scheduler.block_calls, :>=, 1
        assert_equal 0, scheduler.io_wait_calls
      ensure
        resources&.each { it.close unless it.closed? }
        atom&.store(:ready)
      end

      def test_scheduler_reported_timeout_does_not_restart_a_signal_wait
        scheduler_class = Class.new(Helpers::QueueTestScheduler) do
          def io_wait(*)
            @io_wait_calls += 1
            raise "scheduler timeout was retried" if @io_wait_calls > 1
            nil
          end
        end
        [nil, :expired].each do |fallback|
          scheduler = scheduler_class.new
          Fiber.set_scheduler(scheduler)
          signal = Signal.new
          results = []
          Fiber.schedule do
            results << if fallback
                         signal.wait(timeout: 60) { fallback }
                       else
                         signal.wait(timeout: 60)
                       end
          end
          Fiber.set_scheduler(nil)

          assert_equal [fallback], results
          assert_equal 1, scheduler.io_wait_calls
          assert_equal 0, signal.num_waiting
        end
      end

      def test_fallback_lock_handoff_survives_a_notified_waiter_raising
        scheduler_class = Class.new(Helpers::QueueTestScheduler) do
          attr_accessor :cancel_target

          def io_wait(...)
            result = super
            raise "cancel notified fallback" if Fiber.current.equal?(cancel_target)
            result
          end
        end
        scheduler = scheduler_class.new
        Fiber.set_scheduler(scheduler)
        lock = Lock.new
        lock.lock
        events = []
        first = Fiber.schedule do
          lock.synchronize { flunk "cancelled fallback waiter acquired the lock" }
        rescue RuntimeError => e
          events << e.message
        end
        scheduler.cancel_target = first
        Fiber.schedule { lock.synchronize { events << :acquired } }
        lock.unlock
        Fiber.set_scheduler(nil)

        assert_equal ["cancel notified fallback", :acquired], events
        assert_operator scheduler.io_wait_calls, :>=, 2
        refute_predicate lock, :locked?
      ensure
        lock&.unlock if lock&.owned?
      end
    end
  end
end
