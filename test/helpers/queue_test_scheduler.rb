# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Helpers
  # A deliberately small IO.select scheduler derived from Ruby's own scheduler
  # test support: https://github.com/ruby/ruby/blob/master/test/fiber/scheduler.rb
  class QueueTestScheduler
    attr_reader :io_wait_calls, :block_calls, :unblock_calls

    def initialize(root = Fiber.current)
      @root = root
      @readable = {}
      @waiting = {}
      @blocking = {}
      @ready = Thread::Queue.new
      @wakeup_reader, @wakeup_writer = IO.pipe
      @io_wait_calls = 0
      @block_calls = 0
      @unblock_calls = 0
    end

    def fiber(&)
      # A transferred task returns to the root when it finishes or suspends.
      # Keep its caller runnable so nested scheduling can resume the dispatcher.
      @ready << Fiber.current unless Fiber.current.equal?(@root)
      Fiber.new(blocking: false, &).tap(&:transfer)
    end

    def io_wait(io, events, duration)
      @io_wait_calls += 1
      fiber = Fiber.current
      @readable[io] = fiber unless events.nobits?(IO::READABLE)
      @waiting[fiber] = Farce::Clock.now + duration if duration
      @root.transfer
    ensure
      @readable.delete(io)
      @waiting.delete(fiber) if duration
    end

    def kernel_sleep(duration = nil) # rubocop:disable Naming/PredicateMethod
      block(:sleep, duration)
      true
    end

    def block(_blocker, timeout = nil)
      @block_calls += 1
      fiber = Fiber.current
      if timeout
        @waiting[fiber] = Farce::Clock.now + timeout
      else
        @blocking[fiber] = true
      end
      @root.transfer
    ensure
      @waiting.delete(fiber)
      @blocking.delete(fiber)
    end

    def unblock(_blocker, fiber)
      @unblock_calls += 1
      @ready << fiber
      @wakeup_writer.write_nonblock(".")
    rescue IO::WaitWritable, Errno::EPIPE, IOError
    end

    def fiber_interrupt(fiber, exception)
      fiber.raise(exception) if fiber.alive?
    end

    def close
      run while pending?
    ensure
      @wakeup_reader.close unless @wakeup_reader.closed?
      @wakeup_writer.close unless @wakeup_writer.closed?
    end

    alias scheduler_close close

    private

    def pending?
      @readable.any? || @waiting.any? || @blocking.any? || !@ready.empty?
    end

    def next_timeout
      return 0 unless @ready.empty?

      deadline = @waiting.values.min
      deadline && [deadline - Farce::Clock.now, 0].max
    end

    def run
      readable, = select_readable([*@readable.keys, @wakeup_reader], next_timeout)
      drain_wakeup if readable&.delete(@wakeup_reader)
      selected = readable&.filter_map { |io| @readable.delete(io) } || []

      current = Farce::Clock.now
      expired = @waiting.filter_map do |fiber, deadline|
        fiber if deadline <= current
      end
      expired.each { |fiber| @waiting.delete(fiber) }

      selected.uniq.each do |fiber|
        fiber.transfer(IO::READABLE) if fiber.alive?
      end
      (expired + drain_ready).uniq.each do |fiber|
        fiber.transfer if fiber.alive?
      end
    end

    def select_readable(readers, timeout)
      if RUBY_ENGINE == "jruby"
        # JRuby can dispatch io_select even in a blocking/root fiber. Use its
        # primitive below scheduler dispatch without changing the installed scheduler.
        milliseconds = timeout.nil? ? nil : java.lang.Long.valueOf((timeout * 1000).ceil)
        groups = [readers, nil, nil].map { |group| JRuby.reference(group) }
        Java::OrgJrubyUtilIo::SelectExecutor.new(*groups, milliseconds).go(JRuby.runtime.current_context)
      else
        Fiber.blocking { IO.select(readers, nil, nil, timeout) }
      end
    end

    def drain_wakeup
      loop { @wakeup_reader.read_nonblock(4096) }
    rescue IO::WaitReadable, EOFError
    end

    def drain_ready
      fibers = []
      loop { fibers << @ready.pop(true) }
    rescue ThreadError
      fibers
    end
  end
end
