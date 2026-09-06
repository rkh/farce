# frozen_string_literal: true

module Helpers
  # Shared lifetime tests request a minimum transfer. Ruby 4.1 exposes individual
  # bounded transfers instead; loop explicitly so both contracts test the same work.
  module FiberSchedulerIO
    SINGLE_TRANSFER = defined?(IO::Buffer::VERSION) && IO::Buffer::VERSION >= 3

    def scheduler_read(io, buffer, minimum, offset = 0)
      return @scheduler.io_read(io, buffer, minimum, offset) unless SINGLE_TRANSFER
      minimum_transfer(buffer, minimum, offset) { @scheduler.io_read(io, buffer, _1, _2) }
    end

    def scheduler_write(io, buffer, minimum, offset = 0)
      return @scheduler.io_write(io, buffer, minimum, offset) unless SINGLE_TRANSFER
      minimum_transfer(buffer, minimum, offset) { @scheduler.io_write(io, buffer, _1, _2) }
    end

    def buffer_read(io, buffer, minimum, offset = 0)
      return buffer.read(io, minimum, offset) unless SINGLE_TRANSFER
      minimum_transfer(buffer, minimum, offset) { buffer.read(io, _1, _2) }
    end

    def buffer_pread(io, buffer, from, minimum, offset = 0)
      return buffer.pread(io, from, minimum, offset) unless SINGLE_TRANSFER
      minimum_transfer(buffer, minimum, offset) { buffer.pread(io, from + _1 - offset, _1, _2) }
    end

    def buffer_pwrite(io, buffer, from, minimum, offset = 0)
      return buffer.pwrite(io, from, minimum, offset) unless SINGLE_TRANSFER
      minimum_transfer(buffer, minimum, offset) { buffer.pwrite(io, from + _1 - offset, _1, _2) }
    end

    private def minimum_transfer(buffer, minimum, offset)
      minimum, offset = Integer(minimum), Integer(offset)
      total = 0
      loop do
        capacity = [minimum - total, buffer.size - offset - total].max
        capacity = minimum if minimum.negative?
        result = yield(offset + total, capacity)
        return total.positive? ? total : result unless result.positive?
        total += result
        return total if total >= minimum
      end
    end
  end
end
