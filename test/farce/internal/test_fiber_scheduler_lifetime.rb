# frozen_string_literal: true
# IO.select itself is the contract under test; empty fibers test admission.
# rubocop:disable Lint/IncompatibleIoSelectWithFiberScheduler, Lint/EmptyBlock
# Full runtime-dispatch acceptance is CRuby-specific; JRuby probes have a separate suite.
return unless RUBY_ENGINE == "ruby"
require_relative "../../setup"
require "socket"
require "tempfile"

module Farce
  module Internal
    class TestFiberSchedulerLifetime < Test
      include Helpers::FiberSchedulerIO

      def setup
        @scheduler = FiberScheduler.new(backend: ENV.fetch("BACKEND", "auto").to_sym)
        Fiber.set_scheduler(@scheduler)
        @resources = []
      end

      def teardown
        Fiber.set_scheduler(nil)
      ensure
        @resources.each { |io| io.is_a?(Tempfile) ? io.close! : (io.close unless io.closed?) }
      end

      def pair
        Socket.pair(:UNIX, :STREAM, 0).tap { @resources.concat(it) }
      end

      def test_immediate_admission_and_nested_fibers
        order = []
        task = Fiber.schedule do
          order << :parent
          child = Fiber.schedule { order << :child }

          refute_predicate child, :alive?
          order << :after_child
          @scheduler.yield
          order << :resumed
        end

        assert_predicate task, :alive?
        assert_equal %i[parent child after_child], order
        @scheduler.run

        assert_equal %i[parent child after_child resumed], order
      end

      def test_nested_admission_exception_can_be_rescued_by_parent
        events = []
        Fiber.schedule do
          error = assert_raises(ArgumentError) do
            Fiber.schedule { raise ArgumentError, "child failed" }
          end
          assert_equal "child failed", error.message
          Fiber.schedule { events << :next_child }
          @scheduler.yield
          events << :parent_resumed
        end

        assert_equal [:next_child], events
        @scheduler.run

        assert_equal %i[next_child parent_resumed], events
      end

      def test_nested_admission_that_parks_returns_to_parent
        events = []
        Fiber.schedule do
          Fiber.schedule do
            events << :child_started
            @scheduler.yield
            events << :child_resumed
          end
          events << :parent_continued
        end

        assert_equal %i[child_started parent_continued], events
        @scheduler.run

        assert_equal %i[child_started parent_continued child_resumed], events
      end

      def test_old_token_cannot_resume_a_reused_fiber_slot
        first = Fiber.schedule { @scheduler.block(nil) }
        old_token = @scheduler.send(:current_wait, first)
        @scheduler.unblock(nil, first)
        @scheduler.run
        seen = []
        second = Fiber.schedule { seen << @scheduler.block(nil) }
        new_token = @scheduler.send(:current_wait, second)

        refute_equal old_token, new_token
        refute @scheduler.send(:resume_wait, old_token, :stale)
        @scheduler.unblock(nil, second)
        @scheduler.run

        assert_equal [true], seen
      end

      def test_socket_reopen_between_reads_does_not_reuse_an_old_lease
        original, old_writer = pair
        replacement, new_writer = pair
        data = []
        Fiber.schedule { data << original.read(1) }
        Fiber.schedule { old_writer.write("a") }
        @scheduler.run
        original.reopen(replacement)
        Fiber.schedule { data << original.read(1) }
        Fiber.schedule { new_writer.write("b") }
        @scheduler.run

        assert_equal %w[a b], data
      end

      def test_large_read_cancellation_preserves_other_completions_and_unlocks_buffers
        completed = 0
        cancelled = 0
        pairs = Array.new(20) { pair }
        tasks = pairs.map do |reader, _|
          Fiber.schedule do
            buffer = IO::Buffer.new(4096)

            assert_equal 4096, buffer_read(reader, buffer, 4096)
            assert_equal "x" * 4096, buffer.get_string
            completed += 1
          rescue RuntimeError => e
            assert_equal "cancel large read", e.message
            cancelled += 1
          ensure
            refute_predicate buffer, :locked?
            buffer.free
          end
        end
        pairs.take(10).each { |sockets| sockets.last.write("x" * 4096) }
        tasks.drop(10).each { @scheduler.fiber_interrupt(it, RuntimeError.new("cancel large read")) }
        @scheduler.run

        assert_equal 10, completed
        assert_equal 10, cancelled
        assert_equal 0, @scheduler.send(:pending_count)
        GC.compact
      end

      def test_pending_buffer_reads_survive_compaction_and_mixed_cancellation
        buffers = Array.new(24) { IO::Buffer.new(4096) }
        sockets = buffers.map { pair }
        outcomes = Array.new(buffers.size)
        tasks = buffers.each_with_index.map do |buffer, index|
          Fiber.schedule do
            amount = buffer_read(sockets[index].first, buffer, 4096)

            assert_equal 4096, amount
            assert_equal "x" * 4096, buffer.get_string
            outcomes[index] = :completed
          rescue RuntimeError => e
            assert_equal "cancel pending read", e.message
            outcomes[index] = :cancelled
          end
        end

        buffers.each { assert_predicate it, :locked? }
        GC.start
        GC.compact
        tasks.each_with_index do |task, index|
          sockets[index].last.write("x" * 4096) unless (index % 3).zero?
          @scheduler.fiber_interrupt(task, RuntimeError.new("cancel pending read")) unless index % 3 == 2
        end
        @scheduler.run

        assert_equal Array.new(24) { it % 3 == 2 ? :completed : :cancelled }, outcomes
        buffers.each { refute_predicate it, :locked? }

        assert_equal 0, @scheduler.send(:pending_count)
      ensure
        buffers&.each { it.free unless it.locked? }
      end

      def test_closed_buffer_read_does_not_consume_reused_descriptor_data
        reader, = pair
        old_buffer = IO::Buffer.new(3)
        old_buffer.set_string("___")
        outcome = nil
        Fiber.schedule do
          buffer_read(reader, old_buffer, 3)
          outcome = :completed
        rescue IOError
          outcome = :closed
        end
        new_buffer = IO::Buffer.new(3)
        Fiber.schedule do
          reader.close
          replacement, new_writer = pair

          Fiber.schedule do
            assert_equal 3, buffer_read(replacement, new_buffer, 3)
          end
          new_writer.write("new")
        end
        @scheduler.run

        assert_equal :closed, outcome
        refute_equal "new", old_buffer.get_string
        assert_equal "new", new_buffer.get_string
        refute_predicate old_buffer, :locked?
        refute_predicate new_buffer, :locked?
      ensure
        old_buffer&.free unless old_buffer&.locked?
        new_buffer&.free unless new_buffer&.locked?
      end

      def test_copy_and_marshal_are_rejected
        assert_raises(TypeError) { @scheduler.dup }
        assert_raises(TypeError) { @scheduler.clone }
        assert_raises(TypeError) { Marshal.dump(@scheduler) }
      end

      def test_subclass_inherits_io_hooks_and_ownership
        Fiber.set_scheduler(nil)
        child = Class.new(FiberScheduler)
        @scheduler = child.new

        assert_equal FiberScheduler, child.superclass
        Fiber.set_scheduler(@scheduler)
        error = Thread.new do
          @scheduler.run
        rescue StandardError => e
          e
        end.value

        assert_instance_of ThreadError, error
        return unless @scheduler.backend != :select && RUBY_ENGINE == "ruby"
        %i[io_read io_write io_wait].each do |hook|
          assert_nil @scheduler.method(hook).source_location
          assert_equal FiberScheduler, @scheduler.method(hook).owner
        end
      end

      def test_zero_length_read_and_write_and_readonly_destination
        a, b = pair
        Fiber.schedule do
          buffer = IO::Buffer.new(0)

          assert_equal 0, scheduler_read(a, buffer, 0)
          assert_equal 0, scheduler_write(b, buffer, 0)
          readonly = IO::Buffer.for("abc")
          assert_raises(IO::Buffer::AccessError) { scheduler_read(a, readonly, 1) }
          assert_raises(ArgumentError, RangeError) { scheduler_read(a, buffer, 1) }
          assert_raises(ArgumentError, RangeError) { scheduler_write(b, readonly, 1, -1) }
        ensure
          buffer&.free
        end
        @scheduler.run
      end

      def test_select_retains_duplicates_and_wrapper_identity
        a, b = pair
        wrapper = Struct.new(:to_io).new(a)
        result = nil
        Fiber.schedule { result = IO.select([a, wrapper, a], nil, nil, 1) }
        Fiber.schedule { b.write("x") }
        @scheduler.run

        assert_equal [[a, wrapper, a], [], []], result
      end

      def test_buffered_ruby_input_is_selectable
        a, b = pair
        b.write("first\nsecond\n")
        Fiber.schedule do
          assert_equal "first\n", a.gets
          assert_equal [[a], [], []], IO.select([a], nil, nil, 0)
          assert_equal "second\n", a.gets
        end
        @scheduler.run
      end

      def test_coercion_can_close_an_io_before_registration
        a, = pair
        coercible = Object.new
        coercible.define_singleton_method(:to_int) do
          a.close
          1
        end
        Fiber.schedule do
          buffer = IO::Buffer.new(1)
          assert_raises(IOError) { scheduler_read(a, buffer, coercible) }
          refute_predicate buffer, :locked?
          buffer.free
        end
      end

      def test_positional_io_preserves_shared_offset
        file = Tempfile.new("farce-positional")
        @resources << file
        file.write("abcdef")
        file.flush
        file.pos = 2
        Fiber.schedule do
          buffer = IO::Buffer.new(4)

          assert_equal 3, buffer_pread(file, buffer, 3, 2, 1)
          assert_equal "de", buffer.get_string(1, 2)
          assert_equal 2, file.pos
          assert_equal 3, buffer_pwrite(file, buffer, 0, 2, 1)
          assert_equal 2, file.pos
          buffer.free
        end
        @scheduler.run
        file.rewind

        assert_equal "defdef", file.read
      end

      def test_duplicate_wakes_and_interrupt_cannot_escape_into_new_wait
        trace = []
        task = Fiber.schedule do
          @scheduler.block(:one)
          trace << :one
          trace << @scheduler.block(:two, 0.005)
        end
        1000.times { @scheduler.unblock(:one, task) }
        @scheduler.run

        assert_equal [:one, false], trace
      end

      def test_cross_thread_wake_pipe_saturation
        task = Fiber.schedule { @scheduler.block(:waiting) }
        threads = 4.times.map { Thread.new { 20_000.times { @scheduler.unblock(:waiting, task) } } }
        threads.each(&:join)
        @scheduler.run

        refute_predicate task, :alive?
        assert_predicate @scheduler, :idle?
      end

      def test_close_is_idempotent_and_rejects_new_admission
        @scheduler.close

        assert_predicate @scheduler, :closed?
        @scheduler.close
        assert_raises(IOError) { @scheduler.fiber {} }
      end

      def test_close_during_run_drains_existing_and_new_work
        a, b = pair
        trace = []
        Fiber.schedule do
          @scheduler.yield

          assert @scheduler.close
          assert @scheduler.close
          refute_predicate @scheduler, :closed?
          trace << :closing
          Fiber.schedule do
            @scheduler.yield
            trace << :child_finished
          end
          b.write("x")
          @scheduler.yield
          trace << :closer_finished
        end
        Fiber.schedule { trace << a.read(1) }
        @scheduler.run

        assert_includes trace, "x"
        assert_includes trace, :closer_finished
        assert_includes trace, :child_finished
        assert_equal :closing, trace.first
        assert_predicate @scheduler, :closed?
        assert_predicate @scheduler, :idle?
        assert_same @scheduler, Fiber.scheduler
        assert_raises(IOError) { Fiber.schedule {} }
        assert_raises(IOError) { @scheduler.run }
      end

      def test_close_during_immediate_admission_defers_destruction
        Fiber.schedule do
          assert @scheduler.close
          refute_predicate @scheduler, :closed?
          @scheduler.yield
        end
        @scheduler.run

        assert_predicate @scheduler, :closed?
        assert_predicate @scheduler, :idle?
      end

      def test_runtime_uninstall_drains_through_scheduler_close
        finished = false
        Fiber.schedule do
          sleep 0.001
          finished = true
        end
        Fiber.set_scheduler(nil)

        assert finished
        assert_predicate @scheduler, :closed?
        assert_nil Fiber.scheduler
      end

      def test_runtime_uninstall_drains_nested_fibers
        events = []
        Fiber.schedule do
          @scheduler.yield
          Fiber.schedule do
            @scheduler.yield
            events << :child_finished
          end
          events << :parent_finished
        end

        assert_empty events
        Fiber.set_scheduler(nil)

        assert_equal %i[parent_finished child_finished], events
        assert_predicate @scheduler, :closed?
        assert_nil Fiber.scheduler
      end

      def test_thread_exit_drains_through_scheduler_close
        finished = false
        scheduler = Thread.new do
          current = FiberScheduler.new
          Fiber.set_scheduler(current)
          Fiber.schedule do
            sleep 0.001
            finished = true
          end
          current
        end.value

        assert finished
        assert_predicate scheduler, :closed?
      end

      def test_cancelled_queued_background_job_is_not_executed
        Fiber.set_scheduler(nil)
        pool = ThreadPool.new(max_threads: 1, capacity: 2)
        @scheduler = FiberScheduler.new(backend: ENV.fetch("BACKEND", "auto").to_sym, thread_pool: pool)
        Fiber.set_scheduler(@scheduler)
        started = Thread::Queue.new
        release = Thread::Queue.new
        ran = false
        Fiber.schedule do
          @scheduler.send(:background) do
            started << true
            release.pop
          end
        end
        started.pop
        task = Fiber.schedule { @scheduler.send(:background) { ran = true } }
        @scheduler.fiber_interrupt(task, Timeout::Error.new("cancel queued job"))
        releaser = Thread.new do
          sleep 0.02
          release << true
        end
        assert_raises(Timeout::Error) { @scheduler.run }
        refute ran
        refute_predicate task, :alive?
      ensure
        release << true if release
        releaser&.join
        pool&.close
      end

      def test_address_resolution_uses_ruby_resolver
        Fiber.schedule do
          assert_equal ["127.0.0.1"], @scheduler.address_resolve("127.0.0.1")
          addresses = @scheduler.address_resolve("localhost")

          assert_includes addresses, "127.0.0.1"
          assert(Socket.getaddrinfo("localhost", 80).any? { |entry| addresses.include?(entry[3]) })
        end
        @scheduler.run
      end

      def test_select_uses_the_io_resolved_at_admission
        a, b = pair
        other, = pair
        calls = 0
        wrapper = Object.new
        wrapper.define_singleton_method(:to_io) do
          calls += 1
          calls == 1 ? a : other
        end
        result = nil
        Fiber.schedule { result = IO.select([wrapper], nil, nil, 0.03) }
        Fiber.schedule do
          sleep 0.001
          b.write("x")
        end
        @scheduler.run

        assert_equal [[wrapper], [], []], result
        assert_equal 1, calls
      end

      def test_cross_thread_close_settles_a_direct_hook_promptly
        a, = pair
        elapsed = nil
        Fiber.schedule do
          buffer = IO::Buffer.new(1)
          started = Farce::Clock.now
          assert_raises(IOError) { scheduler_read(a, buffer, 1) }
          elapsed = Farce::Clock.now - started

          refute_predicate buffer, :locked?
        ensure
          buffer&.free
        end
        closer = Thread.new do
          sleep 0.005
          a.close
        end
        # Bound the regression even if closing an fd does not wake the OS reactor.
        Fiber.schedule { sleep 0.3 }
        @scheduler.run

        assert_operator elapsed, :<, 0.15
      ensure
        closer&.join
      end

      def test_priority_wait_on_a_pipe_can_expire
        reader, writer = IO.pipe
        @resources.push(reader, writer)
        Fiber.schedule do
          assert_equal 0, @scheduler.io_wait(reader, IO::PRIORITY, 0.005)
          assert_nil IO.select(nil, nil, [reader], 0.005)
        end
        @scheduler.run
      end

      def test_disappearing_select_readiness_is_rearmed
        a, b = pair
        Fiber.set_scheduler(nil)
        consumed = false
        child = Class.new(FiberScheduler) do
          define_method(:select_snapshot) do |groups, timeout|
            result = super(groups, timeout)
            if result && result[0].include?(a) && !consumed
              # Model another reader consuming readiness before select settles.
              a.read_nonblock(1)
              consumed = true
              nil
            else
              result
            end
          end
          private :select_snapshot
        end
        @scheduler = child.new(backend: ENV.fetch("BACKEND", "auto").to_sym)
        Fiber.set_scheduler(@scheduler)
        selected = nil
        Fiber.schedule { selected = IO.select([a], nil, nil, 0.1) }
        Fiber.schedule do
          b.write("x")
          sleep 0.005
          b.write("y")
        end
        @scheduler.run

        assert consumed
        assert_equal [[a], [], []], selected
        assert_equal "y", a.read(1)
      end

      def test_uninstall_during_root_exception_aborts_admitted_work
        events = []
        Fiber.schedule do
          sleep 0.02
          events << :completed
        ensure
          events << :ensured
        end
        error = assert_raises(RuntimeError) do
          raise "root failure"
        ensure
          Fiber.set_scheduler(nil)
        end

        assert_equal "root failure", error.message
        assert_equal [:ensured], events
        assert_predicate @scheduler, :closed?
      end

      def test_finite_and_infinite_waits
        a, b = pair
        Fiber.schedule do
          assert_equal 0, @scheduler.io_wait(a, IO::READABLE, 0)
          assert_equal 0, @scheduler.io_wait(a, IO::READABLE, 0.001)
          assert_equal IO::READABLE, @scheduler.io_wait(a, IO::READABLE, Float::INFINITY)
        end
        Fiber.schedule do
          sleep 0.005
          b.write("x")
        end
        @scheduler.run
      end

      def test_close_and_numeric_descriptor_reuse
        a, = pair
        fd = a.fileno
        seen = []
        Fiber.schedule do
          a.read(1)
        rescue StandardError
          seen << :closed
        end
        Fiber.schedule do
          a.close
          replacement, writer = pair
          Fiber.schedule { seen << replacement.read(1) }
          writer.write("y")
        end
        @scheduler.run

        assert_equal [:closed, "y"], seen
        assert_operator fd, :>=, 0
      end

      def test_timer_added_during_dispatch_interrupts_ready_churn
        count = 0
        observed = nil
        Fiber.schedule do
          @scheduler.yield
          @scheduler.timeout_after(0, Timeout::Error) do
            loop do
              count += 1
              @scheduler.yield
            end
          end
        rescue Timeout::Error
          observed = count
        end
        @scheduler.run

        assert_operator observed, :<=, 256
        assert_predicate @scheduler, :idle?
      end

      def test_notification_during_dispatch_interrupts_ready_churn
        count = 0
        observed = nil
        blocked = Fiber.schedule do
          @scheduler.block(nil)
          observed = count
        end
        Fiber.schedule do
          @scheduler.yield
          @scheduler.unblock(nil, blocked)
          10_000.times do
            count += 1
            @scheduler.yield
          end
        end
        @scheduler.run

        assert_operator observed, :<=, 257
        assert_predicate @scheduler, :idle?
      end

      def test_timeout_during_ready_churn
        count = 0
        observed = nil
        Fiber.schedule do
          sleep 0
          observed = count
        end
        100.times do
          Fiber.schedule do
            100.times do
              count += 1
              @scheduler.yield
            end
          end
        end
        @scheduler.run

        assert_operator observed, :<, 10_000
      end
    end

    # rubocop:enable Lint/IncompatibleIoSelectWithFiberScheduler, Lint/EmptyBlock
  end
end
