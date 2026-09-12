# frozen_string_literal: true

return unless RUBY_ENGINE == "ruby"

require_relative "../../setup"
require "weakref"

class TestUnsharedSignalPool < Test
  Signal = Farce.const_get(:Internal)::UnsharedIOSignal
  class Interrupted < StandardError; end

  class Scheduler < Helpers::QueueTestScheduler
    attr_reader :handles
    attr_accessor :on_wait, :defer_interrupt

    Interrupt = Struct.new(:fiber, :exception) do
      def alive? = fiber.alive?
      def transfer = fiber.raise(exception)
    end

    def initialize
      super
      @handles = []
    end

    def fiber_interrupt(fiber, exception)
      return super unless @defer_interrupt
      unblock(nil, Interrupt.new(fiber, exception))
    end

    def io_wait(io, events, timeout)
      @handles << io
      @on_wait&.call(io)
      super
    end

    def tick
      @readable.delete_if { |io, _| io.closed? }
      run
    end
  end

  def setup
    @scheduler = Scheduler.new
    Fiber.set_scheduler(@scheduler)
  end

  def teardown
    Fiber.set_scheduler(nil)
  end

  def test_reuses_owned_handles_across_waits
    signal = Signal.new
    results = []
    Fiber.schedule { 40.times { results << signal.wait } }
    40.times do
      signal.broadcast
      @scheduler.tick
    end

    assert_equal (1..40).to_a, results
    assert_equal 40, @scheduler.handles.size
    assert_equal 1, @scheduler.handles.map(&:object_id).uniq.size
    assert @scheduler.handles.all?(&:autoclose?)
    assert @scheduler.handles.all?(&:close_on_exec?)
    assert_equal 0, signal.num_waiting
  end

  def test_cancellation_after_notification_retires_the_handle
    signal = Signal.new
    fiber = Fiber.schedule do
      signal.wait
    rescue Interrupted
      nil
    end
    signal.broadcast
    fiber.raise(Interrupted)
    timed_out = false
    Fiber.schedule { timed_out = signal.wait(timeout: 0.005).nil? }
    @scheduler.tick

    assert timed_out
    assert_equal 2, @scheduler.handles.size
    refute_same(*@scheduler.handles)
    assert_predicate @scheduler.handles.first, :closed?
    assert_equal 0, signal.num_waiting
  end

  def test_scheduler_exception_releases_the_slot
    signal = Signal.new
    @scheduler.on_wait = ->(_) { raise Interrupted }

    assert_raises(Interrupted) { Fiber.schedule { signal.wait } }
    assert_equal 0, signal.num_waiting
    @scheduler.on_wait = nil
    Fiber.schedule { signal.wait }
    signal.broadcast
    @scheduler.tick

    refute_same(*@scheduler.handles)
    assert_predicate @scheduler.handles.first, :closed?
    assert_equal 0, signal.num_waiting
  end

  def test_closed_handle_is_retired_without_closing_a_reused_descriptor
    signal = Signal.new
    unrelated = nil
    @scheduler.on_wait = lambda do |io|
      begin
        io.close
      rescue IOError
        # CRuby interrupts the currently waiting fiber when its IO closes.
      end
      unrelated = File.open(File::NULL) # rubocop:disable Style/FileOpen
      raise Interrupted
    end
    assert_raises(Interrupted) { Fiber.schedule { signal.wait } }
    assert_equal "", unrelated.read
    old = @scheduler.handles.last
    @scheduler.on_wait = nil
    Fiber.schedule { signal.wait }
    signal.broadcast
    @scheduler.tick

    refute_same old, @scheduler.handles.last
    assert_predicate old, :closed?
    assert_equal "", unrelated.read
    assert_equal 0, signal.num_waiting
  ensure
    unrelated&.close
  end

  def test_idle_handle_closed_by_scheduler_does_not_close_another_file
    signal = Signal.new
    Fiber.schedule { signal.wait }
    signal.broadcast
    @scheduler.tick
    old = @scheduler.handles.last
    descriptor = old.fileno
    old.close
    unrelated = File.open(File::NULL) # rubocop:disable Style/FileOpen

    assert_equal descriptor, unrelated.fileno
    assert_raises(IOError) { Fiber.schedule { signal.wait } }
    assert_equal "", unrelated.read
    Fiber.schedule { signal.wait }
    signal.broadcast
    @scheduler.tick

    refute_same old, @scheduler.handles.last
    assert_equal "", unrelated.read
    assert_equal 0, signal.num_waiting
  ensure
    unrelated&.close
  end

  def test_closing_an_active_handle_unwinds_before_releasing_ownership
    skip "CRuby 3.4 does not interrupt scheduled IO waits on close" if RUBY_VERSION.start_with?("3.")
    signal = Signal.new
    result = nil
    Fiber.schedule do
      signal.wait
    rescue IOError
      result = :closed
    end
    old = @scheduler.handles.last
    @scheduler.defer_interrupt = true
    closer = Fiber.schedule { old.close }
    @scheduler.tick while closer.alive?

    assert_equal :closed, result
    assert_predicate old, :closed?
    assert_equal 0, signal.num_waiting
    Fiber.schedule { signal.wait }
    signal.broadcast
    @scheduler.tick
    GC.verify_compaction_references(double_heap: true, toward: :empty)

    refute_same old, @scheduler.handles.last
    assert_equal 0, signal.num_waiting
  end

  def test_active_slots_are_distinct_and_idle_retention_is_bounded
    signal = Signal.new
    results = []
    count = Gem.win_platform? ? 60 : 100
    count.times { Fiber.schedule { results << signal.wait } }

    assert_equal count, signal.num_waiting
    assert_equal count, @scheduler.handles.map(&:fileno).uniq.size
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    signal.broadcast
    @scheduler.tick

    assert_equal [1] * count, results
    assert_equal(2, @scheduler.handles.count { !it.closed? })
    assert_equal count - 2, @scheduler.handles.count(&:closed?)
    assert_equal 0, signal.num_waiting
  end

  def test_repeated_timeouts_do_not_accumulate_slots
    signal = Signal.new
    results = []
    Fiber.schedule { 30.times { results << signal.wait(timeout: 0.0001) } }
    30.times { @scheduler.tick }

    assert_equal [nil] * 30, results
    assert_equal 1, @scheduler.handles.map(&:object_id).uniq.size
    assert_equal 0, signal.num_waiting
  end

  def test_notification_during_pipe_allocation_is_observed
    signal = Signal.new
    singleton = IO.singleton_class
    singleton.alias_method :owned_pool_original_pipe, :pipe
    singleton.define_method(:pipe) do |*args, **keywords|
      signal.broadcast
      owned_pool_original_pipe(*args, **keywords)
    end
    result = nil
    Fiber.schedule { result = signal.wait }

    assert_equal 1, result
    assert_empty @scheduler.handles
    assert_equal 0, signal.num_waiting
  ensure
    if singleton&.method_defined?(:owned_pool_original_pipe)
      singleton.remove_method :pipe
      singleton.alias_method :pipe, :owned_pool_original_pipe
      singleton.remove_method :owned_pool_original_pipe
    end
  end

  def test_failed_pipe_allocation_leaves_signal_usable
    signal = Signal.new
    singleton = IO.singleton_class
    singleton.alias_method :owned_pool_original_pipe, :pipe
    singleton.define_method(:pipe) { raise Errno::EMFILE }

    assert_raises(Errno::EMFILE) { Fiber.schedule { signal.wait } }
    assert_equal 0, signal.num_waiting
    singleton.remove_method :pipe
    singleton.alias_method :pipe, :owned_pool_original_pipe
    singleton.remove_method :owned_pool_original_pipe
    Fiber.schedule { signal.wait }
    signal.broadcast
    @scheduler.tick

    assert_equal 0, signal.num_waiting
  ensure
    if singleton&.method_defined?(:owned_pool_original_pipe)
      singleton.remove_method :pipe
      singleton.alias_method :pipe, :owned_pool_original_pipe
      singleton.remove_method :owned_pool_original_pipe
    end
  end

  def test_pool_collection_releases_idle_descriptors
    skip "open descriptor count is not available" unless File.directory?("/dev/fd")
    3.times { GC.start }
    before = Dir.children("/dev/fd").size
    references = 20.times.map { make_idle_pool }
    @scheduler.handles.clear
    3.times { GC.start }

    assert references.none?(&:weakref_alive?)
    assert_equal before, Dir.children("/dev/fd").size
  end

  private def make_idle_pool
    signal = Signal.new
    Fiber.schedule { signal.wait }
    signal.broadcast
    @scheduler.tick
    WeakRef.new(signal)
  end
end
