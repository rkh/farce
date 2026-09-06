# frozen_string_literal: true
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
