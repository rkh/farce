# frozen_string_literal: true
require "fcntl"
require "socket"
require "io/nonblock"

module Farce
  module Internal
    # IO hooks and helpers shared by the scheduler implementations.
    module SchedulerIO
      def io_select(readers = nil, writers = nil, errors = nil, timeout = nil)
        check_fiber
        timeout = duration_value(timeout)
        groups  = [readers, writers, errors].map { |list| list.nil? ? [] : list.to_ary.dup }
        ios     = groups.map { |list| list.map(&:to_io) }
        check_fiber # to_ary/to_io can run arbitrary Ruby

        found = select_result(groups, ios, 0)
        return checkpoint_result(found) if found || timeout&.zero?
        token = arm_wait

        register_select(token, groups, ios)
        wait_with_timeout(token, timeout, nil)
      ensure
        retire_wait(token) if token
      end

      SINGLE_TRANSFER = defined?(IO::Buffer::VERSION) && IO::Buffer::VERSION >= 3
      private_constant :SINGLE_TRANSFER

      if SINGLE_TRANSFER
        def io_pread(io, buffer, file_offset, offset, length)
          positional_io(false, io, buffer, length, file_offset, offset, single_transfer: true)
        end

        def io_pwrite(io, buffer, file_offset, offset, length)
          positional_io(true, io, buffer, length, file_offset, offset, single_transfer: true)
        end
      else
        def io_pread(io, buffer, file_offset, minimum, offset = 0)
          positional_io(false, io, buffer, minimum, file_offset, offset)
        end

        def io_pwrite(io, buffer, file_offset, minimum, offset = 0)
          positional_io(true, io, buffer, minimum, file_offset, offset)
        end
      end

      private

      def owner_thread = Thread.current
      def start_fiber(fiber) = fiber.resume
      def policy_changed = nil
      def dispatch_budget = 256
      def finish_fiber = nil
      def begin_close = nil
      def begin_shutdown = nil

      def select_snapshot(groups, timeout)
        Fiber.blocking { IO.select(*groups, timeout) }
      end

      # Coercion belongs to admission. A mutable wrapper must not switch the IO
      # being observed after its wait has been registered.
      def select_result(groups, ios, timeout)
        selected = select_snapshot(ios, timeout)
        return unless selected
        identities = selected.map do |list|
          list.each_with_object({}.compare_by_identity) { |io, set| set[io] = true }
        end
        groups.each_with_index.map do |list, i|
          list.each_with_index.filter_map { |object, j| object if identities[i].key?(ios[i][j]) }
        end
      end

      def readiness(result)
        return 0 unless result
        (result[0].empty? ? 0 : IO::READABLE) |
          (result[1].empty? ? 0 : IO::WRITABLE) |
          (result[2].empty? ? 0 : IO::PRIORITY)
      end

      def transfer_arguments(io, buffer, minimum, offset, writing)
        check_fiber
        io = io.to_io
        minimum, offset = Integer(minimum), Integer(offset)
        check_fiber
        io.fileno
        raise ArgumentError, "minimum and offset exceed buffer size" if
          minimum.negative? || offset.negative? || offset > buffer.size || minimum > buffer.size - offset
        raise IO::Buffer::AccessError, "buffer is readonly" if !writing && buffer.readonly?
        [io, minimum, offset]
      end

      def locked_buffer(buffer, &work)
        !SINGLE_TRANSFER && buffer.locked? ? work.call : buffer.locked(&work)
      end

      def duplicate_io(io, writing)
        # IO#dup flushes Ruby's buffers. During an io_write hook that would flush
        # the same payload twice. Duplicate the descriptor below Ruby buffering.
        Fiber.blocking do
          copy = IO.for_fd(io.fcntl(Fcntl::F_DUPFD, 0), writing ? "w" : "r")
          copy.close_on_exec = true
          copy
        end
      end

      def positional_io(writing, io, buffer, minimum, file_offset, offset, single_transfer: false)
        io, minimum, offset = transfer_arguments(io, buffer, minimum, offset, writing)
        file_offset = Integer(file_offset)
        check_fiber
        locked_buffer(buffer) do
          copy = duplicate_io(io, writing)
          capacity = single_transfer ? minimum : buffer.size - offset
          minimum = capacity.zero? ? 0 : 1 if single_transfer
          data = buffer.get_string(offset, capacity) if writing
          value = background do
            worker_transfer(copy, writing, data, capacity, minimum, file_offset)
          end
          if writing || value.is_a?(Integer)
            value
          else
            buffer.set_string(value, offset)
            value.bytesize
          end
        ensure
          copy&.close
        end
      end

      # File workers own copies. A cancelled caller waits for acknowledgement
      # before its ensure closes the duplicated IO or releases any borrowed state.
      def file_transfer(writing, io, buffer, minimum, offset, capacity = buffer.size - offset)
        copy = duplicate_io(io, writing)
        data = buffer.get_string(offset, capacity) if writing
        value = background do
          worker_transfer(copy, writing, data, capacity, minimum)
        end
        return value if writing || value.is_a?(Integer)
        buffer.set_string(value, offset)
        value.bytesize
      ensure
        copy&.close
      end

      def worker_transfer(io, writing, data, capacity, minimum, position = nil)
        total = 0
        output = +"".b
        return writing ? 0 : output if capacity.zero?
        loop do
          remaining = capacity - total
          if writing
            chunk = data.byteslice(total, remaining)
            amount = position ? io.pwrite(chunk, position + total) : io.syswrite(chunk)
          else
            chunk = position ? io.pread(remaining, position + total) : io.sysread(remaining)
            output << chunk
            amount = chunk.bytesize
          end
          total += amount
          break if amount.zero? || total >= minimum
        end
        writing ? total : output
      rescue EOFError
        output
      rescue SystemCallError => e
        total.positive? ? (writing ? total : output) : -e.errno
      end
    end
  end
end
