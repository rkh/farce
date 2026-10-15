# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true
return unless RUBY_ENGINE == "jruby"
require_relative "../../setup"
require "socket"

# Exercise the hooks directly and observe which calls the runtime dispatches.
# Runtime capabilities may change independently of Farce releases.
module Farce
  module Internal
    class TestFiberSchedulerJRuby < Test
      def setup
        @scheduler = FiberScheduler.new
        Fiber.set_scheduler(@scheduler)
        @resources = []
      end

      def teardown
        Fiber.set_scheduler(nil)
      ensure
        @resources.each { |io| io.close unless io.closed? }
      end

      def test_logical_thread_ownership_and_cooperative_sleep_hook
        order = []
        Fiber.schedule do
          order << :start
          @scheduler.kernel_sleep(0.001)
          order << :done
        end

        assert_equal [:start], order
        @scheduler.run

        assert_equal %i[start done], order
        assert_instance_of ThreadError, Thread.new {
          begin
            @scheduler.run
          rescue StandardError => e
            e
          end
        }.value
      end

      def test_nio_socket_readiness_and_buffer_transfer
        listener = TCPServer.new("127.0.0.1", 0)
        a = TCPSocket.new("127.0.0.1", listener.local_address.ip_port)
        b = listener.accept
        @resources.push(listener, a, b)
        Fiber.schedule do
          buffer = IO::Buffer.new(3)

          assert_equal 3, @scheduler.io_read(a, buffer, 3)
          assert_equal "abc", buffer.get_string
          refute_predicate buffer, :locked?
          buffer.free
        end
        Fiber.schedule do
          @scheduler.kernel_sleep(0.001)
          buffer = IO::Buffer.for("abc")

          assert_equal 3, @scheduler.io_write(b, buffer, 3)
        end
        @scheduler.run
      end

      def test_runtime_created_buffers_transfer_strings
        reader, writer = Socket.pair(:UNIX, :STREAM, 0)
        @resources.push(reader, writer)
        writer.write("hello")
        Fiber.schedule do
          assert_equal "hello", reader.read(5)
          assert_equal 5, reader.write("world")
        end
        @scheduler.run

        assert_equal "world", writer.read(5)
      end

      def test_hook_adapter_preserves_normal_and_empty_buffers
        [IO::Buffer.new(4), IO::Buffer.new(0)].each do |buffer|
          native = JRuby.reference(buffer)
          native.lock(JRuby.runtime.current_context)

          assert_same buffer, @scheduler.send(:nio_hook_buffer, buffer)
        ensure
          native.unlock(JRuby.runtime.current_context)
          buffer.free
        end
      end

      def test_hook_adapter_uses_the_backing_range_and_preserves_readonly
        base = java.nio.ByteBuffer.wrap("__data__".to_java_bytes)
        base.position(2)
        base.limit(6)
        flags = Java::OrgJruby::RubyIOBuffer::LOCKED | Java::OrgJruby::RubyIOBuffer::READONLY
        buffer = Java::OrgJruby::RubyIOBuffer.newBuffer(JRuby.runtime.current_context, base, 0, flags)
        adapted = @scheduler.send(:nio_hook_buffer, buffer)

        assert_equal 4, adapted.size
        assert_equal "data", adapted.get_string
        assert_predicate adapted, :readonly?
        assert_raises(IO::Buffer::AccessError) { adapted.set_string("fail") }
        assert_equal 0, buffer.size
        assert_predicate buffer, :locked?
        assert_equal 2, base.position
        assert_equal 6, base.limit
      ensure
        JRuby.reference(buffer).unlock(JRuby.runtime.current_context) if buffer&.locked?
        adapted&.free
        buffer&.free
      end

      def test_cross_thread_unblock_and_stale_generation
        task = Fiber.schedule do
          assert @scheduler.block(:first)
          refute @scheduler.block(:second, 0.005)
        end
        Thread.new { 100.times { @scheduler.unblock(:first, task) } }.join
        @scheduler.run

        refute_predicate task, :alive?
      end

      def test_mutex_notification_before_registration_is_consumed_once
        mutex = Mutex.new
        results = []
        Fiber.schedule do
          fiber = Fiber.current

          assert(Fiber.blocking { Thread.new { @scheduler.unblock(mutex, fiber) }.value })
          results << @scheduler.block(mutex, 0)
          results << @scheduler.block(mutex, 0)
        end
        @scheduler.run

        assert_equal [true, false], results
        assert_predicate @scheduler, :idle?
      end

      def test_early_mutex_notification_does_not_resume_a_different_blocker
        first = Mutex.new
        second = Mutex.new
        results = []
        Fiber.schedule do
          assert @scheduler.unblock(first, Fiber.current)
          results << @scheduler.block(second, 0)
          results << @scheduler.block(first, 0)
        end
        @scheduler.run

        assert_equal [false, false], results
      end

      def test_io_wait_retires_an_early_mutex_notification
        reader, writer = IO.pipe
        @resources.push(reader, writer)
        mutex = Mutex.new
        result = nil
        Fiber.schedule do
          assert @scheduler.unblock(mutex, Fiber.current)
          assert_equal 0, @scheduler.io_wait(reader, IO::READABLE, 0.001)
          result = @scheduler.block(mutex, 0)
        end
        @scheduler.run

        refute result
      end

      def test_late_mutex_notification_does_not_interrupt_an_io_wait
        reader, writer = IO.pipe
        @resources.push(reader, writer)
        result = nil
        fiber = Fiber.schedule { result = @scheduler.io_wait(reader, IO::READABLE) }
        accepted = @scheduler.unblock(Mutex.new, fiber)
        writer.write("ready")
        @scheduler.run

        refute accepted
        assert_equal IO::READABLE, result
      end

      def test_duplicate_mutex_notifications_cannot_resume_a_later_wait
        mutex = Mutex.new
        results = []
        fiber = Fiber.schedule do
          results << @scheduler.block(mutex)
          results << @scheduler.block(mutex, 0)
        end
        Thread.new { 100.times { @scheduler.unblock(mutex, fiber) } }.join
        @scheduler.run

        assert_equal [true, false], results
      end

      def test_finished_fibers_release_early_mutex_notifications
        mutex = Mutex.new
        fiber = Fiber.schedule { assert @scheduler.unblock(mutex, Fiber.current) }

        refute @scheduler.unblock(mutex, fiber)
        refute @scheduler.unblock(mutex, Fiber.current)
        assert_empty @scheduler.instance_variable_get(:@mutex_wakeups)
      end

      def test_cancelled_fibers_release_early_mutex_notifications
        mutex = Mutex.new
        interrupted = false
        fiber = Fiber.schedule do
          assert @scheduler.unblock(mutex, Fiber.current)
          @scheduler.block(:other)
        rescue IOError
          interrupted = true
        end

        assert @scheduler.fiber_interrupt(fiber, IOError.new("cancel wait"))
        @scheduler.run

        assert interrupted
        refute @scheduler.unblock(mutex, fiber)
        assert_empty @scheduler.instance_variable_get(:@mutex_wakeups)
      end

      def test_close_discards_early_mutex_notifications
        mutex = Mutex.new
        fiber = Fiber.schedule do
          assert @scheduler.unblock(mutex, Fiber.current)
          @scheduler.block(:other)
        end
        @scheduler.send(:shutdown)
        @scheduler.close

        refute_predicate fiber, :alive?
        refute @scheduler.unblock(mutex, fiber)
        assert_empty @scheduler.instance_variable_get(:@mutex_wakeups)
      end

      def test_wait_registry_mutex_does_not_invoke_scheduler_callbacks
        mutex = @scheduler.instance_variable_get(:@wait_mutex)
        states = []
        Fiber.schedule do
          states << Fiber.current.blocking?

          assert_equal(:locked, mutex.synchronize do
            states << Fiber.current.blocking?
            :locked
          end)
          states << Fiber.current.blocking?
          assert_raises(IOError) { mutex.synchronize { raise IOError, "release lock" } }
          refute_predicate mutex, :locked?
        end

        assert_equal [false, true, false], states
      end

      def test_timeout_unlocks_borrowed_buffer
        a, b = Socket.pair(:UNIX, :STREAM, 0)
        @resources.push(a, b)
        Fiber.schedule do
          buffer = IO::Buffer.new(16)
          assert_raises(Timeout::Error) do
            @scheduler.timeout_after(0.001) { @scheduler.io_read(a, buffer, 1) }
          end
          refute_predicate buffer, :locked?
          buffer.free
        end
        @scheduler.run
      end

      def test_signal_wait_in_a_blocking_fiber_during_shutdown
        output, error, status = ruby_isolated(<<~RUBY)
          require "farce"
          internal = Farce.const_get(:Internal)
          scheduler = internal::FiberScheduler.new
          Fiber.set_scheduler(scheduler)
          signal = internal::Signal.new
          results = []
          original = Fiber.method(:current_scheduler)
          Fiber.schedule do
            scheduler.kernel_sleep(0.001)
            blocking = Fiber.new(blocking: true) do
              results << signal.wait(timeout: 0.05) { :timed_out }
            end
            # JRuby can expose the installed scheduler to a blocking fiber during shutdown.
            Fiber.define_singleton_method(:current_scheduler) do
              Fiber.current.equal?(blocking) ? scheduler : original.call
            end
            blocking.resume
          end
          Fiber.set_scheduler(nil)
          abort "wait did not time out" unless results == [:timed_out]
          abort "waiter leaked" unless signal.num_waiting == 0
          puts "ok"
        RUBY

        assert_predicate status, :success?, error
        assert_equal "ok\n", output
        assert_empty error
      end

      def test_runtime_sleep_order_matches_hook_dispatch
        order = []
        dispatched = false
        @scheduler.define_singleton_method(:kernel_sleep) do |duration|
          dispatched = true
          super(duration)
        end
        Fiber.schedule do
          sleep 0.001
          order << :slept
        end
        order << :returned
        @scheduler.run

        expected = dispatched ? %i[returned slept] : %i[slept returned]

        assert_equal expected, order
      end
    end
  end
end
