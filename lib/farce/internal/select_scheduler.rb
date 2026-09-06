# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal
    # Ruby scheduler built around IO.select. Engine implementations can override its IO helpers.
    module SelectScheduler
      include SchedulerIO

      Wait = Struct.new(:fiber, :status, :value, :error, :groups, :ios)
      private_constant :Wait

      attr_reader :backend, :fallback_reason

      def initialize(backend: :auto)
        raise ArgumentError, "unavailable select driver: #{backend}" unless %i[auto select].include?(backend)
        @backend = :select
        @wait_mutex = Thread::Mutex.new
        @waits = {}
        @waiting = {}.compare_by_identity
        @ready = []
        @serial = 0
        @wake_reader, @wake_writer = IO.pipe
      end

      def io_wait(io, events, timeout = nil)
        check_fiber
        events = Integer(events)
        raise ArgumentError, "invalid IO event mask" unless events.positive? && events.nobits?(~7)
        readiness(io_select(events.nobits?(IO::READABLE) ? nil : [io],
          events.nobits?(IO::WRITABLE) ? nil : [io], events.nobits?(IO::PRIORITY) ? nil : [io], timeout))
      end

      if SINGLE_TRANSFER
        def io_read(io, buffer, offset, length)
          transfer_io(false, io, buffer, length, offset, single_transfer: true)
        end

        def io_write(io, buffer, offset, length)
          transfer_io(true, io, buffer, length, offset, single_transfer: true)
        end
      else
        def io_read(io, buffer, minimum, offset = 0)
          transfer_io(false, io, buffer, minimum, offset)
        end

        def io_write(io, buffer, minimum, offset = 0)
          transfer_io(true, io, buffer, minimum, offset)
        end
      end

      def io_close(descriptor) # rubocop:disable Naming/PredicateMethod
        check_owner
        cancel_descriptor(descriptor)
        Fiber.blocking { IO.for_fd(descriptor).close }
        true
      end

      private

      def arm_wait
        check_fiber
        @wait_mutex.synchronize do
          token = @serial += 1
          @waits[token] = Wait.new(Fiber.current, :pending)
          @waiting[Fiber.current] = token
          token
        end
      end

      def current_wait(fiber)
        @wait_mutex.synchronize { @waiting[fiber] }
      end

      def register_select(token, groups, ios)
        wait = @waits.fetch(token)
        wait.groups, wait.ios = groups, ios
      end

      def park_current(token)
        Fiber.yield
        wait = @waits.fetch(token)
        raise wait.error if wait.error
        wait.value
      ensure
        retire_wait(token)
      end

      def resume_wait(token, value, error = nil)
        @wait_mutex.synchronize do
          wait = @waits[token]
          return false unless wait && wait.status == :pending
          wait.status, wait.value, wait.error = :ready, value, error
          @ready << token
          true
        end
      end

      def interrupt_wait(token, error)
        # An interrupt may replace an undispatched result, but never a later wait.
        @wait_mutex.synchronize do
          wait = @waits[token]
          return false unless wait
          @ready << token if wait.status == :pending
          wait.status, wait.error = :ready, error
          true
        end
      end

      def retire_wait(token)
        @wait_mutex.synchronize do
          wait = @waits.delete(token)
          @waiting.delete(wait.fiber) if wait && @waiting[wait.fiber] == token
        end
      end

      def ready? = !@ready.empty?
      def pending? = !@waits.empty?
      def pending_count = @wait_mutex.synchronize { @waits.size }

      def write_wakeup = @wake_writer.write_nonblock(".", exception: false)
      def read_wakeup = @wake_reader.read_nonblock(4096, exception: false)

      def wakeup
        write_wakeup
        true
      rescue IOError, SystemCallError
        false
      end

      def dispatch(timeout, budget)
        check_root
        snapshot = @waits.to_a.select { |_, wait| wait.status == :pending && wait.groups }
        groups = [[@wake_reader], [], []]
        snapshot.each do |token, wait|
          if wait.ios.flatten.any?(&:closed?)
            interrupt_wait(token, IOError.new("stream closed while waiting"))
          else
            3.times { |i| groups[i].concat(wait.ios[i]) }
          end
        end
        # Linux select may keep sleeping after another thread closes an IO.
        timeout = [timeout || 0.05, 0.05].min unless snapshot.empty?
        begin
          found = select_snapshot(groups.map(&:uniq), ready? ? 0 : timeout)
        rescue IOError, Errno::EBADF
          closed = snapshot.select { |_, wait| wait.ios.flatten.any?(&:closed?) }
          raise if closed.empty?
          closed.each { |token, _| interrupt_wait(token, IOError.new("stream closed while waiting")) } # rubocop:disable Style/HashEachMethods -- snapshot is an Array
        end
        if found
          if found[0].delete(@wake_reader)
            loop { break unless read_wakeup.is_a?(String) }
          end
          sets = found.map { |list| list.each_with_object({}.compare_by_identity) { |io, set| set[io] = true } }
          snapshot.each do |token, wait|
            next unless @waits[token].equal?(wait) && wait.status == :pending
            result = wait.groups.each_with_index.map do |list, i|
              list.each_with_index.filter_map { |object, j| object if sets[i][wait.ios[i][j]] }
            end
            resume_wait(token, result) if result.any? { |list| !list.empty? }
          end
        end
        count = 0
        budget.times do
          token = @ready.shift
          break unless token
          wait = @waits[token]
          next unless wait && wait.status == :ready
          wait.status = :delivered
          wait.fiber.resume
          count += 1
        end
        count
      rescue Errno::EINTR
        0
      end

      def cancel_descriptor(descriptor)
        @waits.each do |token, wait|
          next unless wait.ios&.flatten&.any? { |io| !io.closed? && io.fileno == descriptor }
          interrupt_wait(token, IOError.new("stream closed while waiting"))
        end
      end

      def destroy
        @wake_reader.close if @wake_reader && !@wake_reader.closed?
        @wake_writer.close if @wake_writer && !@wake_writer.closed?
        @waits&.clear
        @waiting&.clear
        @ready&.clear
      end

      def transfer_nonblock(writing, io, buffer, offset, capacity)
        writing ? io.write_nonblock(buffer.get_string(offset, capacity), exception: false) :
          io.read_nonblock(capacity, exception: false)
      end

      def transfer_io(writing, io, buffer, minimum, offset, single_transfer: false)
        io, minimum, offset = transfer_arguments(io, buffer, minimum, offset, writing)
        limit = single_transfer ? minimum : buffer.size - offset
        minimum = limit.zero? ? 0 : 1 if single_transfer
        serial = @suspensions
        result = locked_buffer(buffer) do
          operation = lambda do |*_ignored|
            next file_transfer(writing, io, buffer, minimum, offset, limit) if io.stat.file?
            total = 0
            loop do
              capacity = limit - total
              break total if capacity.zero?
              value = Fiber.blocking do
                transfer_nonblock(writing, io, buffer, offset + total, capacity)
              end
              if value == :wait_readable || value == :wait_writable
                io_wait(io, value == :wait_readable ? IO::READABLE : IO::WRITABLE)
                next
              end
              break total if value.nil? || value == 0 # rubocop:disable Style/NumericPredicate -- reads return strings, writes integers
              buffer.set_string(value, offset + total) unless writing
              total += writing ? value : value.bytesize
              break total if total >= minimum
            end
          rescue SystemCallError => e
            total&.positive? ? total : -e.errno
          end
          io.respond_to?(:timeout) && io.timeout ? with_io_timeout(io.timeout, &operation) : operation.call
        end
        checkpoint_result(result) if serial == @suspensions
        result
      end
    end
  end
end
