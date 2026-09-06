# frozen_string_literal: true
# IO.select itself is the contract under test; empty fibers test admission.
# rubocop:disable Lint/IncompatibleIoSelectWithFiberScheduler, Lint/EmptyBlock
# Full runtime-dispatch acceptance is CRuby-specific; JRuby probes have a separate suite.
return unless RUBY_ENGINE == "ruby"
ENV["MT_NO_PLUGINS"] = "1"
require_relative "../../setup"
require "minitest/autorun"
require "tempfile"

module Farce
  module Internal
    class TestFiberSchedulerIOHooks < Test
      include Helpers::FiberSchedulerIO

      def setup
        @resources = []
        @scheduler = FiberScheduler.new(backend: ENV.fetch("BACKEND", "auto").to_sym)
        Fiber.set_scheduler(@scheduler)
      end

      def teardown
        Fiber.set_scheduler(nil)
      ensure
        @resources.reverse_each { |io| io.close unless io.closed? }
      end

      def pair
        Socket.pair(:UNIX, :STREAM, 0).tap { @resources.concat(it) }
      end

      def run(&work)
        return super unless work
        Fiber.schedule(&work)
        @scheduler.run

        assert_predicate @scheduler, :idle?
      end

      def test_partial_reads_and_offsets
        a, b = pair
        Fiber.schedule do
          b.write("ab")
          sleep 0.002
          b.write("cd")
          b.close
        end
        run do
          buffer = IO::Buffer.new(8)

          assert_equal 4, scheduler_read(a, buffer, 4, 2)
          assert_equal "abcd", buffer.get_string(2, 4)
          assert_equal 0, scheduler_read(a, buffer, 1, 0)
          buffer.free
        end
      end

      def test_read_timeout_cancel_and_reuse
        a, b = pair
        ready = Thread::Queue.new
        Fiber.schedule do
          ready.pop
          b.write("new")
        end
        run do
          3.times do
            buffer = IO::Buffer.new(4096)
            assert_raises(IO::TimeoutError) do
              @scheduler.timeout_after(0.0002, IO::TimeoutError) { scheduler_read(a, buffer, 1, 0) }
            end
            refute_predicate buffer, :locked?
            buffer.free
            GC.start
          end
          ready << true

          assert_equal "new", a.read(3)
        end
      end

      def test_io_timeout_property
        a, = pair
        a.timeout = 0.001

        run do
          assert_raises(IO::TimeoutError) { a.read(1) }
        end
      end

      def test_close_pending_read_runs_ensure_and_unlocks
        a, = pair
        buffer = IO::Buffer.new(4096)
        Fiber.schedule do
          assert_raises(IOError) { scheduler_read(a, buffer, 1, 0) }
          refute_predicate buffer, :locked?
          buffer.free
        end
        Fiber.schedule do
          sleep 0.001

          assert_predicate buffer, :locked?
          assert_raises(IO::Buffer::LockedError) { buffer.resize(8192) }
          a.close
        end
        @scheduler.run

        assert_predicate @scheduler, :idle?
      end

      def test_queue_and_cross_thread_notification
        queue = Thread::Queue.new
        thread = Thread.new do
          sleep 0.002
          queue << 42
        end

        run { assert_equal 42, queue.pop }
        thread.join
      end

      def test_duplicate_unblock_does_not_wake_later_wait
        finished = false
        target = Fiber.schedule do
          assert @scheduler.block(:one)
          refute @scheduler.block(:two, 0.005)
          finished = true
        end
        Fiber.schedule do
          @scheduler.unblock(:one, target)
          @scheduler.unblock(:one, target)
        end
        @scheduler.run

        assert finished
      end

      def test_combined_wait_and_zero_timeout_masks
        a, b = pair
        run do
          assert_equal 0, @scheduler.io_wait(a, IO::READABLE, 0)
          assert_equal IO::WRITABLE, @scheduler.io_wait(a, IO::READABLE | IO::WRITABLE, 0)
          b.write("x")

          assert_equal IO::READABLE, @scheduler.io_wait(a, IO::READABLE, 0)
        end
      end

      def test_multiwaiter_and_io_select_fallback
        a, b = pair
        seen = []
        2.times { Fiber.schedule { seen << @scheduler.io_wait(a, IO::READABLE, 0.1) } }
        Fiber.schedule do
          sleep 0.002
          b.write("x")
        end
        @scheduler.run

        assert_equal [IO::READABLE, IO::READABLE], seen
        run { assert_equal [[a], [], []], IO.select([a], nil, nil, 0) }
      end

      def test_select_timeout_and_cancellation
        a, = pair
        run do
          assert_nil IO.select([a], nil, nil, 0.001)
          assert_raises(Timeout::Error) { Timeout.timeout(0.001) { IO.select([a]) } }
        end
      end

      def test_pipe_and_file_fallback
        a, b = IO.pipe
        @resources.push(a, b)
        Fiber.schedule do
          sleep 0.001
          b.write("pipe")
        end

        run { assert_equal "pipe", a.read(4) }
        file = Tempfile.new("farce-reactor")
        file.write("file")
        file.rewind

        run { assert_equal "file", file.read }
      ensure
        file&.close!
      end

      def test_immediate_io_allows_timer_to_run
        a, b = pair
        b.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDBUF, 65536)
        b.write("x" * 10000)
        observed = nil
        count = 0
        Fiber.schedule do
          sleep 0
          observed = count
        end
        Fiber.schedule do
          buffer = IO::Buffer.new(1)
          10000.times do
            scheduler_read(a, buffer, 1, 0)
            count += 1
          end
          buffer.free
        end
        @scheduler.run

        assert_operator observed, :<, 10000
      end

      def test_exceptional_shutdown_cancels_other_reads
        a, = pair
        cleaned = false
        Fiber.schedule do
          buffer = IO::Buffer.new(4096)
          begin
            scheduler_read(a, buffer, 1, 0)
          ensure
            refute_predicate buffer, :locked?
            buffer.free
            cleaned = true
          end
        end
        Fiber.schedule do
          @scheduler.yield
          Kernel.raise "task failed"
        end
        error = assert_raises(RuntimeError) { @scheduler.run }
        assert_equal "task failed", error.message
        assert cleaned
      end

      def test_owner_and_uninstalled_checks
        thread = Thread.new { assert_raises(ThreadError) { @scheduler.fiber {} } }
        thread.join
        a, = pair
        buffer = IO::Buffer.new(1)
        assert_raises(FiberError) { scheduler_read(a, buffer, 1, 0) }
        buffer.free
      end

      def test_thread_exit_drains_scheduler
        result = []
        Thread.new do
          Fiber.set_scheduler(FiberScheduler.new)
          Fiber.schedule do
            sleep 0.001
            result << :done
          end
        end.join

        assert_equal [:done], result
      end

      def test_close_interrupts_background_select
        a, = pair

        Fiber.schedule { assert_raises(IOError) { IO.select([a]) } }
        Fiber.schedule do
          sleep 0.001
          a.close
        end
        @scheduler.run

        assert_predicate @scheduler, :idle?
      end

      def test_large_partial_write_and_read
        a, b = pair
        a.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDBUF, 4096)
        payload = "a" * (256 * 1024)
        Fiber.schedule do
          sleep 0.001

          assert_equal payload, b.read(payload.bytesize)
        end
        run do
          buffer = IO::Buffer.for(payload)

          assert_equal payload.bytesize, scheduler_write(a, buffer, payload.bytesize, 0)
        end
      end

      def test_gc_during_cancelled_read_and_immediate_buffer_release
        a, = pair
        queue = Thread::Queue.new
        thread = Thread.new do
          20.times do
            queue.pop
            GC.start
            GC.compact
          end
        end
        run do
          20.times do
            buffer = IO::Buffer.new(4096)
            queue << true
            assert_raises(Timeout::Error) { Timeout.timeout(0.0001) { scheduler_read(a, buffer, 1, 0) } }
            buffer.free
          end
        end
        thread.join
      end

      def test_nested_timeout_does_not_interrupt_later_sleep
        run do
          assert_equal :done, @scheduler.timeout_after(0.0001, Timeout::Error) { :done }
          assert_raises(Timeout::Error) do
            @scheduler.timeout_after(0.001, Timeout::Error) do
              @scheduler.timeout_after(1, IOError) { sleep 1 }
            end
          end
          sleep 0.002
        end
      end

      def test_yield_runs_once_and_remains_fair
        counts = Array.new(20, 0)
        20.times do |i|
          Fiber.schedule do
            10.times do
              counts[i] += 1
              @scheduler.yield
            end
          end
        end
        @scheduler.run

        assert_equal [10] * 20, counts
        assert_predicate @scheduler, :idle?
      end

      def test_dispatch_budget_with_many_connections
        completed = 0
        connections = 32
        budget = 8
        connections.times do
          a, b = pair
          Fiber.schedule do
            @scheduler.yield
            20.times do
              a.write("x")

              assert_equal "y", a.read(1)
            end
            completed += 1
          end
          Fiber.schedule do
            @scheduler.yield
            20.times do
              assert_equal "x", b.read(1)
              b.write("y")
            end
            completed += 1
          end
        end
        # Exhaust a small budget with work still pending, without requiring thousands of file descriptors.
        assert_equal budget, @scheduler.send(:dispatch, 0, budget)
        refute_predicate @scheduler, :idle?
        assert_operator completed, :<, connections * 2

        @scheduler.run

        assert_equal connections * 2, completed
        assert_predicate @scheduler, :idle?
      end

      def test_invalid_recursive_run_does_not_abort_other_fibers
        seen = []
        Fiber.schedule do
          assert_raises(FiberError) { @scheduler.run }
          assert_raises(FiberError) { @scheduler.scheduler_close }
          seen << :first
        end
        Fiber.schedule do
          sleep 0.001
          seen << :second
        end
        @scheduler.run

        assert_equal %i[first second], seen
      end

      def test_aborting_fiber_cannot_submit_another_kernel_read
        a, = pair
        rejected = false
        Fiber.schedule do
          buffer = IO::Buffer.new(8)
          begin
            scheduler_read(a, buffer, 1, 0)
          rescue FiberScheduler.const_get(:Cancelled)
            assert_raises(IOError) { scheduler_read(a, buffer, 1, 0) }
            rejected = true
          ensure
            buffer.free
          end
        end
        Fiber.schedule do
          @scheduler.yield
          Kernel.raise "stop"
        end
        assert_raises(RuntimeError) { @scheduler.run }
        assert rejected
      end

      def test_close_interrupt_does_not_escape_into_the_next_read
        a, = pair
        c, d = pair
        Fiber.schedule do
          assert_raises(IOError) { a.read(1) }
          assert_equal "y", c.read(1)
        end
        Fiber.schedule do
          sleep 0.001
          a.close
          sleep 0.001
          d.write("y")
        end
        @scheduler.run

        assert_predicate @scheduler, :idle?
      end

      def test_gc_can_mark_a_retained_closed_scheduler
        Fiber.schedule { sleep 0.0001 }
        Fiber.set_scheduler(nil)

        assert_predicate @scheduler, :closed?
        10.times do
          GC.start
          GC.compact
        end

        assert_predicate @scheduler, :closed?
      end

      def test_immediate_readiness_and_select_allow_timers
        a, b = pair
        b.write("x")
        %i[io_wait io_select].each do |method|
          count = 0
          observed = nil
          Fiber.schedule do
            sleep 0
            observed = count
          end
          Fiber.schedule do
            10000.times do
              method == :io_wait ? @scheduler.io_wait(a, IO::READABLE, 0) : @scheduler.io_select([a], nil, nil, 0)
              count += 1
            end
          end
          @scheduler.run

          assert_operator observed, :<, 10000
        end
      end
    end

    # rubocop:enable Lint/IncompatibleIoSelectWithFiberScheduler, Lint/EmptyBlock
  end
end
