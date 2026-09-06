# frozen_string_literal: true
return unless RUBY_ENGINE == "ruby"
require_relative "../../setup"
return unless defined?(IO::Buffer::VERSION) && IO::Buffer::VERSION >= 3
require "tempfile"

module Farce
  module Internal
    class TestFiberSchedulerBufferContract < Test
      def setup
        @scheduler = FiberScheduler.new(backend: ENV.fetch("BACKEND", "auto").to_sym)
        Fiber.set_scheduler(@scheduler)
        @reader, @writer = Socket.pair(:UNIX, :STREAM, 0)
        @buffer = IO::Buffer.new(8)
        @buffer.set_string("________")
      end

      def teardown
        Fiber.set_scheduler(nil)
        @reader.close
        @writer.close
        @buffer.free
      end

      def test_hook_returns_a_short_read_and_respects_buffer_offset
        @writer.write("ab")
        Fiber.schedule do
          assert_equal 2, @scheduler.io_read(@reader, @buffer, 1, 4)
          assert_equal "_ab_____", @buffer.get_string
        end
        @scheduler.run
      end

      def test_runtime_buffer_reads_and_writes_respect_maximum_length
        @writer.write("abcdef")
        Fiber.schedule do
          assert_equal 2, @buffer.read(@reader, 3, 2)
          assert_equal "___ab___", @buffer.get_string
          assert_equal "cdef", @reader.read(4)
          assert_equal 2, @buffer.write(@reader, 3, 2)
          assert_equal "ab", @writer.read(2)
        end
        @scheduler.run
      end

      def test_zero_length_does_not_wait_or_transfer
        task = Fiber.schedule do
          assert_equal 0, @buffer.read(@reader, 3, 0)
          assert_equal 0, @buffer.write(@reader, 3, 0)
          assert_equal "________", @buffer.get_string
        end

        refute_predicate task, :alive?
        assert_equal :wait_readable, @writer.read_nonblock(1, exception: false)
      end

      def test_file_and_positional_operations_use_bounded_ranges
        file = Tempfile.new("farce-buffer-contract")
        file.write("abcdef")
        file.flush
        file.pos = 2
        Fiber.schedule do
          assert_equal 2, @buffer.read(file, 1, 2)
          assert_equal "_cd_____", @buffer.get_string
          assert_equal 4, file.pos
          assert_equal 2, @buffer.pread(file, 0, 4, 2)
          assert_equal "_cd_ab__", @buffer.get_string
          assert_equal 4, file.pos
          assert_equal 2, @buffer.pwrite(file, 1, 4, 2)
          assert_equal 4, file.pos
          assert_equal 2, @buffer.write(file, 1, 2)
        end
        @scheduler.run
        file.rewind

        assert_equal "aabdcd", file.read
      ensure
        file&.close!
      end

      def test_nested_buffer_lock_survives_transfer_and_exception
        @writer.write("x")
        Fiber.schedule do
          @buffer.locked do
            assert_equal 1, @buffer.read(@reader, 0, 1)
            assert_predicate @buffer, :locked?
            assert_raises(Timeout::Error) do
              @scheduler.timeout_after(0.001) { @buffer.read(@reader, 0, 1) }
            end
            assert_predicate @buffer, :locked?
          end
          refute_predicate @buffer, :locked?
        end
        @scheduler.run
      end
    end
  end
end
