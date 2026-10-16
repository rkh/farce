# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

return if RUBY_ENGINE == "ruby"
require_relative "../../setup"

module Farce
  module Internal
    class TestShimRactorSelect < Test
      def setup
        @ports   = []
        @threads = []
        @ractors = []
      end

      def teardown
        @threads.each { it.kill.join }
        @ractors.each do |ractor|
          ractor.send(:done) if ractor.alive?
          ractor.join
        end
        @ports.each(&:close)
      end

      def test_ready_ports_preserve_source_and_false_or_nil_messages
        first, second = port, port
        [false, nil, :message].each do |message|
          second.send(message)
          first.send(:sentinel)

          assert_equal [first, :sentinel], Ractor.select(first, second, timeout: 0)
          assert_equal [second, message], Ractor.select(first, second, timeout: 0)
          assert_nil Ractor.select(first, second, timeout: 0)
        end
      end

      def test_waiting_selection_wakes_for_a_message
        input = port
        registered = registrations(input)
        reader = thread { Ractor.select(input) }
        registered.pop
        input.send(:message)

        assert_equal [input, :message], result(reader)
        assert_empty input.instance_variable_get(:@select_waiters)
      end

      def test_overlapping_selections_do_not_consume_losing_messages
        first, second, third = port, port, port
        registered = registrations(second)
        completed = Thread::Queue.new
        left = thread { completed << [:left, Ractor.select(first, second)] }
        right = thread { completed << [:right, Ractor.select(third, second)] }
        2.times { registered.pop }
        second.send(:shared)
        side, selected = completed.pop

        assert_equal [second, :shared], selected
        remaining = side == :left ? third : first
        remaining.send(:remaining)

        assert_equal [remaining, :remaining], completed.pop.last
        result(left)
        result(right)
        [first, second, third].each do |input|
          assert_nil input.receive(timeout: 0)
          assert_empty input.instance_variable_get(:@select_waiters)
        end
      end

      def test_concurrent_selections_receive_each_message_once
        input = port
        registered = registrations(input)
        readers = Array.new(2) { thread { Ractor.select(input) } }
        2.times { registered.pop }
        input.send(:first)
        input.send(:second)

        assert_equal %i[first second], readers.map { result(it).last }.sort
        assert_nil input.receive(timeout: 0)
      end

      def test_timeout_preserves_later_port_and_ractor_values
        input = port
        worker = ractor

        assert_nil Ractor.select(input, worker, timeout: 0.01)
        assert_empty input.instance_variable_get(:@select_waiters)
        assert_empty FakeRactor::STATES[worker].monitors
        input.send(:later)
        worker.send(:result)

        assert_equal [input, :later], Ractor.select(input, timeout: 0)
        assert_equal [worker, :result], Ractor.select(worker)
      end

      def test_cancellation_removes_waiters_and_monitors
        input = port
        worker = ractor
        registered = registrations(input)
        reader = thread { Ractor.select(worker, input) }
        registered.pop
        reader.kill.join

        assert_empty input.instance_variable_get(:@select_waiters)
        assert_empty FakeRactor::STATES[worker].monitors
        input.send(:later)
        worker.send(:result)

        assert_equal :later, input.receive
        assert_equal :result, worker.value
      end

      def test_closing_a_port_wakes_selection_with_closed_error
        input = port
        registered = registrations(input)
        reader = thread do
          Ractor.select(input)
        rescue Ractor::ClosedError => e
          e
        end
        registered.pop
        input.close

        assert_instance_of Ractor::ClosedError, result(reader)
        assert_empty input.instance_variable_get(:@select_waiters)
      end

      def test_already_closed_port_raises_and_cleans_up
        input = port
        worker = ractor
        input.close

        assert_raises(Ractor::ClosedError) { Ractor.select(worker, input, timeout: 0) }
        assert_empty input.instance_variable_get(:@select_waiters)
        assert_empty FakeRactor::STATES[worker].monitors
      end

      def test_terminated_ractor_values_can_be_selected_repeatedly
        [false, nil, :result].each do |value|
          worker = Ractor.new(value) { it }
          worker.join

          2.times { assert_equal [worker, value], Ractor.select(worker, timeout: 0) }
          assert_empty FakeRactor::STATES[worker].monitors
        end
      end

      def test_ractor_failure_is_raised_and_monitor_is_removed
        worker = Ractor.new do
          Thread.current.report_on_exception = false
          raise "selection failure"
        end
        error = assert_raises(RuntimeError) { Ractor.select(worker) }

        assert_equal "selection failure", error.message
        assert_empty FakeRactor::STATES[worker].monitors
      end

      def test_invalid_sources_do_not_consume_ready_messages
        input = port
        input.send(:ready)

        assert_raises(ArgumentError) { Ractor.select }
        assert_raises(ArgumentError) { Ractor.select(input, Object.new) }
        assert_equal :ready, input.receive
      end

      def test_invalid_timeouts_do_not_consume_ready_messages
        input = port
        input.send(:ready)

        assert_raises(ArgumentError) { Ractor.select(input, timeout: -1) }
        [Float::INFINITY, Float::NAN].each do |timeout|
          assert_raises(RangeError) { Ractor.select(input, timeout:) }
        end
        ["0", Object.new, false].each do |timeout|
          assert_raises(TypeError) { Ractor.select(input, timeout:) }
        end
        assert_equal :ready, input.receive
      end

      def test_duplicate_sources_receive_only_one_value
        input = port
        input.send(:first)
        input.send(:second)

        assert_equal [input, :first], Ractor.select(input, input)
        assert_equal :second, input.receive
        assert_empty input.instance_variable_get(:@select_waiters)
      end

      def test_selection_inside_another_ractor
        worker = Ractor.new do
          input = Ractor::Port.new
          input.send(:message)
          Ractor.select(input, timeout: 0).last
        ensure
          input&.close
        end

        assert_equal :message, worker.value
      end

      def test_selection_yields_to_other_scheduled_fibers
        return unless Fiber.respond_to?(:set_scheduler)
        scheduler = FiberScheduler.new
        Fiber.set_scheduler(scheduler)
        input = port
        events = []
        Fiber.schedule { events << Ractor.select(input, timeout: 1) }
        Fiber.schedule do
          events << :sender
          input.send(:message)
        end
        scheduler.run

        assert_equal [:sender, [input, :message]], events
      ensure
        Fiber.set_scheduler(nil) if scheduler
      end

      private

      def port
        input = Ractor::Port.new
        @ports << input
        input
      end

      def ractor
        worker = Ractor.new { Ractor.receive }
        @ractors << worker
        worker
      end

      def thread(&)
        reader = Thread.new(&)
        @threads << reader
        reader
      end

      def result(reader)
        assert reader.join(5), "selection did not finish"
        reader.value
      end

      def registrations(input)
        registered = Thread::Queue.new
        input.define_singleton_method(:register_selector) do |waiter|
          super(waiter)
          registered << true
        end
        registered
      end
    end
  end
end
