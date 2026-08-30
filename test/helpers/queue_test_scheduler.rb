# frozen_string_literal: true

module Helpers
  # A deliberately small IO.select scheduler derived from Ruby's own scheduler
  # test support: https://github.com/ruby/ruby/blob/master/test/fiber/scheduler.rb
  class QueueTestScheduler
    attr_reader :io_wait_calls

    def initialize(root = Fiber.current)
      @root = root
      @readable = {}
      @waiting = {}
      @blocking = {}
      @ready = []
      @io_wait_calls = 0
    end

    def fiber(&)
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
      @ready << fiber
    end

    def fiber_interrupt(fiber, exception)
      fiber.raise(exception) if fiber.alive?
    end

    def close
      run while pending?
    end

    alias scheduler_close close

    private

    def pending?
      @readable.any? || @waiting.any? || @blocking.any? || @ready.any?
    end

    def next_timeout
      deadline = @waiting.values.min
      deadline && [deadline - Farce::Clock.now, 0].max
    end

    def run
      readable, = IO.select(@readable.keys, nil, nil, next_timeout)
      selected = readable&.filter_map { |io| @readable.delete(io) } || []

      current = Farce::Clock.now
      expired = @waiting.filter_map do |fiber, deadline|
        fiber if deadline <= current
      end
      expired.each { |fiber| @waiting.delete(fiber) }

      ready, @ready = @ready, []
      selected.uniq.each do |fiber|
        fiber.transfer(IO::READABLE) if fiber.alive?
      end
      (expired + ready).uniq.each do |fiber|
        fiber.transfer if fiber.alive?
      end
    end
  end
end
