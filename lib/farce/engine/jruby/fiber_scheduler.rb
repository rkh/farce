# frozen_string_literal: true

module Farce
  module Internal
    case FROZEN_CONFIG.fiber_scheduler_implementation
    when :jvm
      # Load the JVM implementation below.
    when :native
      raise LoadError, "the native fiber scheduler requires CRuby"
    when :select
      raise LoadError, "the select scheduler currently requires CRuby"
    end

    require "farce/engine/jruby/fiber_scheduler.jar"
    Java::OrgFarce::FiberScheduler.load(JRuby.runtime)

    class FiberScheduler
      include SelectScheduler
      prepend SchedulerLifecycle

      def initialize(backend: :auto)
        raise ArgumentError, "unavailable JVM driver: #{backend}" unless %i[auto nio].include?(backend)
        super(backend: :select)
        @backend = :nio
        nio_initialize
      end

      def io_read(io, buffer, minimum, offset = 0)
        buffer = nio_hook_buffer(buffer)
        super
      end

      def io_write(io, buffer, minimum, offset = 0)
        buffer = nio_hook_buffer(buffer)
        super
      end

      private :nio_initialize, :nio_select, :nio_destroy, :nio_wakeup, :nio_hook_buffer

      private

      def locked_buffer(buffer)
        return yield if buffer.locked?
        native = JRuby.reference(buffer)
        native.lock(JRuby.runtime.current_context)
        begin
          yield
        ensure
          native.unlock(JRuby.runtime.current_context)
        end
      end

      def owner_thread = JRuby.reference(Thread.current).getFiberCurrentThread

      def select_snapshot(groups, timeout)
        found = nio_select(groups, timeout)
        return unless found
        # JRuby's combined-set select can drop READABLE. Probe each set as well.
        groups.each_with_index do |list, index|
          next if list.empty?
          isolated = [[], [], []]
          isolated[index] = list
          extra = nio_select(isolated, 0)
          found[index] |= extra[index] if extra
        end
        found
      end

      def write_wakeup
        buffer = IO::Buffer.for(".")
        transfer_nonblock(true, @wake_writer, buffer, 0, 1)
      end

      def read_wakeup
        transfer_nonblock(false, @wake_reader, nil, 0, 4096)
      end

      def wakeup
        super
        nio_wakeup
      end

      def destroy
        nio_destroy
        super if @wake_reader
      end

      def transfer_nonblock(writing, io, buffer, offset, capacity)
        file = JRuby.reference(io).getOpenFileChecked
        file.setNonblock(JRuby.runtime)
        # Duplicated JRuby channels cache blocking state separately from fd flags.
        posix = JRuby.runtime.posix
        fd = file.fd.realFileno
        if fd >= 0 && posix.isNative
          flags = posix.fcntl(fd, Java::JnrConstantsPlatform::Fcntl::F_GETFL)
          raise SystemCallError.new("scheduler IO flags", posix.errno) if flags.negative?
          nonblock = Java::JnrConstantsPlatform::OpenFlags::O_NONBLOCK.intValue
          if flags.nobits?(nonblock) && posix.fcntlInt(fd, Java::JnrConstantsPlatform::Fcntl::F_SETFL,
            flags | nonblock).negative?
            raise SystemCallError.new("scheduler IO flags", posix.errno)
          end
        end
        bytes = writing ? buffer.get_string(offset, capacity).to_java_bytes : Java.byte[capacity].new
        shim = file.posix
        count = writing ? shim.write(file.fd, bytes, 0, capacity, true) : shim.read(file.fd, bytes, 0, capacity, true)
        if count.negative?
          errno = shim.getErrno&.intValue || posix.errno
          if [Errno::EAGAIN::Errno, Errno::EWOULDBLOCK::Errno].include?(errno)
            return writing ? :wait_writable : :wait_readable
          end
          raise SystemCallError.new("scheduler IO", errno.zero? ? Errno::EIO::Errno : errno)
        end
        return count if writing
        return if count.zero?
        String.from_java_bytes(java.util.Arrays.copyOf(bytes, count))
      end
    end
  end
end
