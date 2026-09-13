# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

return unless RUBY_ENGINE == "ruby"
require_relative "../../setup"

module Farce
  module Internal
    class TestSelectScheduler < Test
      class Scheduler
        include SelectScheduler
        prepend SchedulerLifecycle

        attr_accessor :before_select

        private

        def select_snapshot(groups, timeout)
          callback, @before_select = @before_select, nil
          callback&.call
          super
        end
      end

      class FailingIO
        def initialize(*results)
          @results = results
        end

        def sysread(*)
          result = @results.shift
          raise result if result.is_a?(Exception)
          result
        end
        alias syswrite sysread
      end

      def setup
        @scheduler = Scheduler.new(backend: :select)
        @reader, @writer = IO.pipe
        Fiber.set_scheduler(@scheduler)
      end

      def teardown
        Fiber.set_scheduler(nil)
      ensure
        [@reader, @writer].each { |io| io.close unless io.closed? }
      end

      def test_close_interrupts_only_the_matching_descriptor
        result = []
        Fiber.schedule do
          result << assert_raises(IOError) { @scheduler.io_wait(@reader, IO::READABLE) }
        end
        Fiber.schedule { @scheduler.kernel_sleep(0.001) }

        assert @scheduler.io_close(@reader.fileno)
        @reader.autoclose = false
        @scheduler.run

        assert_equal 1, result.size
        assert_equal "stream closed while waiting", result.first.message
      end

      def test_dispatch_detects_an_already_closed_stream
        result = []
        Fiber.schedule do
          result << assert_raises(IOError) { @scheduler.io_wait(@reader, IO::READABLE) }
        end
        @reader.close
        @scheduler.run

        assert_equal 1, result.size
      end

      def test_dispatch_handles_a_stream_closed_during_select
        result = []
        Fiber.schedule do
          result << assert_raises(IOError) { @scheduler.io_wait(@reader, IO::READABLE) }
        end
        @scheduler.before_select = -> { @reader.close }
        @scheduler.run

        assert_equal 1, result.size
      end

      def test_unrelated_select_errors_are_propagated
        @scheduler.before_select = -> { raise Errno::EBADF }

        assert_raises(Errno::EBADF) { @scheduler.send(:dispatch, 0, 1) }
      end

      def test_interrupted_select_can_be_retried
        @scheduler.before_select = -> { raise Errno::EINTR }

        assert_equal 0, @scheduler.send(:dispatch, 0, 1)
        assert_equal 0, @scheduler.send(:dispatch, 0, 1)
      end

      def test_wakeup_after_close_returns_false
        Fiber.set_scheduler(nil)

        refute @scheduler.send(:wakeup)
      end

      def test_buffer_transfers_validate_ranges_and_preserve_offsets
        buffer = IO::Buffer.new(8)
        buffer.set_string("________")
        @writer.write("ab")
        Fiber.schedule do
          if SchedulerIO.const_get(:SINGLE_TRANSFER)
            assert_equal 2, @scheduler.io_read(@reader, buffer, 1, 2)
            assert_equal 2, @scheduler.io_write(@writer, buffer, 1, 2)
          else
            assert_equal 2, @scheduler.io_read(@reader, buffer, 2, 1)
            assert_equal 2, @scheduler.io_write(@writer, buffer, 2, 6)
          end

          assert_equal "_ab_____", buffer.get_string
          [[-1, 0], [0, -1], [9, 0], [8, 1]].each do |first, second|
            assert_raises(ArgumentError) { @scheduler.io_read(@reader, buffer, first, second) }
          end
        end
        @scheduler.run

        assert_equal SchedulerIO.const_get(:SINGLE_TRANSFER) ? "ab" : "__", @reader.read(2)
      ensure
        buffer&.free
      end

      def test_socket_transfer_returns_negative_errno
        @reader.close
        buffer = IO::Buffer.new(8)

        Fiber.schedule do
          assert_equal(-Errno::EPIPE::Errno, @scheduler.io_write(@writer, buffer, 1, 1))
        end
        @scheduler.run
      ensure
        buffer&.free
      end

      def test_file_transfer_preserves_progress_on_system_errors
        error = Errno::EIO.new

        assert_equal(-error.errno, @scheduler.send(:worker_transfer, FailingIO.new(error), false, nil, 4, 4))
        assert_equal(-error.errno, @scheduler.send(:worker_transfer, FailingIO.new(error), true, "abcd", 4, 4))
        assert_equal "ab", @scheduler.send(:worker_transfer, FailingIO.new("ab", error), false, nil, 4, 4)
        assert_equal 2, @scheduler.send(:worker_transfer, FailingIO.new(2, error), true, "abcd", 4, 4)
      end

      def test_process_wait_returns_the_child_status
        pid = Process.spawn(*ruby_command("exit 7", coverage: false))
        status = nil
        Fiber.schedule { status = @scheduler.process_wait(pid, 0) }
        @scheduler.run

        assert_equal pid, status.pid
        assert_equal 7, status.exitstatus
      ensure
        begin
          Process.wait(pid) if pid
        rescue Errno::ECHILD
          # The scheduler already reaped the child.
        end
      end
    end
  end
end
