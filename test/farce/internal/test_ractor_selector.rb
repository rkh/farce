# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

return unless RUBY_ENGINE == "ruby"
require_relative "../../setup"

module Farce
  module Internal
    class TestRactorSelector < Test
      def setup
        @scheduler = FiberScheduler.new(backend: ENV.fetch("BACKEND", "auto").to_sym)
        Fiber.set_scheduler(@scheduler)
        @ports = []
      end

      def teardown
        @ports.each { |port| port.close unless port.closed? }
        Fiber.set_scheduler(nil)
      end

      def port
        @ports << Farce::Port.new
        @ports.last
      end

      def test_receive_yields_and_nil_is_a_message
        input = port
        events = []
        Fiber.schedule { events << input.receive }
        Fiber.schedule do
          events << :sender
          input.send(nil)
        end
        @scheduler.run

        assert_equal [:sender, nil], events
      end

      def test_select_multiplexes_independent_and_overlapping_waits
        first, second, third = port, port, port
        results = []
        Fiber.schedule { results << Ractor.select(first, second) }
        Fiber.schedule { results << Ractor.select(second, third) }
        Fiber.schedule do
          third.send(:third)
          first.send(:first)
        end
        @scheduler.run

        assert_equal([[first, :first], [third, :third]], results.sort_by { |result| result[1].to_s })
      end

      def test_timeout_and_zero_timeout_preserve_later_messages
        input = port
        result = :unset
        Fiber.schedule { result = input.receive(timeout: 0.01) }
        @scheduler.run

        assert_nil result
        input.send(:later)

        assert_equal :later, input.receive(timeout: 0)
        assert_nil Ractor.select(input, timeout: 0)
      end

      def test_cancellation_unregisters_wait_without_losing_next_message
        input = port
        cancelled = false
        waiter = Fiber.schedule { input.receive }
        @scheduler.fiber_interrupt(waiter, Timeout::Error.new)
        begin
          @scheduler.run
        rescue Timeout::Error
          cancelled = true
        end

        assert cancelled
        input.send(:later)

        assert_equal :later, input.receive(timeout: 0)
      end

      def test_delivered_but_unclaimed_message_is_recovered
        input = port
        waiter = Fiber.schedule do
          input.receive
        rescue Timeout::Error
          :cancelled
        end
        input.send(:retained)
        Timeout.timeout(5) { Thread.pass until @scheduler.farce_runnable_count.positive? }
        # Interrupt after the result has been queued but before the fiber resumes.
        waiter.raise(Timeout::Error.new)
        @scheduler.run

        assert_equal :retained, input.receive
        refute_predicate RactorSelector.current, :closed?
      end

      def test_closed_port_does_not_break_other_waits
        first, second = port, port
        closed = result = nil
        Fiber.schedule do
          first.receive
        rescue ::Ractor::ClosedError
          closed = true
        end
        Fiber.schedule { result = second.receive }
        Fiber.schedule do
          first.close
          second.send(:ok)
        end
        @scheduler.run

        assert closed
        assert_equal :ok, result
      end

      def test_default_receive_yields
        events = []
        Fiber.schedule { events << Farce::Ractor.receive(timeout: 1) }
        Fiber.schedule do
          events << :sender
          ::Ractor.current.send(:message)
        end
        @scheduler.run

        assert_equal %i[sender message], events
      end

      def test_private_recv_yields
        events = []
        Fiber.schedule { events << ::Ractor.current.instance_eval { recv } }
        Fiber.schedule do
          events << :sender
          ::Ractor.current.send(:message)
        end
        @scheduler.run

        assert_equal %i[sender message], events
      end

      def test_value_or_take_and_select_yield
        worker = ::Ractor.new { ::Ractor.receive }
        result = nil
        Fiber.schedule { result = RUBY_VERSION >= "4" ? worker.value : worker.take }
        Fiber.schedule { worker.send(:done) }
        @scheduler.run

        assert_equal :done, result

        worker = ::Ractor.new { ::Ractor.receive }
        Fiber.schedule { result = Farce::Ractor.select(worker, timeout: 1) }
        Fiber.schedule { worker.send(:selected) }
        @scheduler.run

        assert_equal [worker, :selected], result
      end

      def test_join_does_not_consume_value
        return if RUBY_VERSION < "4"
        worker = ::Ractor.new { ::Ractor.receive }
        joined = nil
        Fiber.schedule { joined = worker.join }
        Fiber.schedule { worker.send([:value]) }
        @scheduler.run

        assert_same worker, joined
        assert_equal [:value], worker.value
      end

      def test_selector_is_shared_between_threads
        selector = nil
        Fiber.schedule do
          port.receive(timeout: 0)
          selector = RactorSelector.current
        end
        @scheduler.run

        assert_same selector, Thread.new { RactorSelector.current }.value
      end

      def test_foreign_native_port_fails_without_hanging
        return if RUBY_VERSION < "4"
        foreign = ::Ractor.new { ::Ractor::Port.new }.value
        assert_raises(::Ractor::Error) { RactorSelector.current.ractor_receive(foreign, timeout: 0) }
      end

      def test_local_values_keep_identity_across_the_helper
        input = Farce::Port.new(mode: :local)
        @ports << input
        object = Object.new
        result = nil
        Fiber.schedule { result = input.receive }
        Fiber.schedule { input.send(object) }
        @scheduler.run

        assert_same object, result
      end

      def test_timeout_does_not_consume_a_later_ractor_result
        worker = ::Ractor.new { ::Ractor.receive }
        result = :unset
        Fiber.schedule { result = Farce::Ractor.select(worker, timeout: 0) }
        @scheduler.run

        assert_nil result
        worker.send(:later)
        result = nil
        Fiber.schedule { result = Farce::Ractor.select(worker, timeout: 1) }
        @scheduler.run

        assert_equal [worker, :later], result
      end

      def test_closing_selector_wakes_its_waiters
        output, error, status = ruby_subprocess(<<~RUBY)
          require "farce"
          internal = Farce.const_get(:Internal)
          selector = internal::RactorSelector.current
          scheduler = internal::FiberScheduler.new
          Fiber.set_scheduler(scheduler)
          input = Farce::Port.new
          failed = false
          Fiber.schedule do
            input.receive
          rescue IOError
            failed = true
          end
          selector.close
          scheduler.run
          input.close
          Fiber.set_scheduler(nil)
          raise "waiter did not wake" unless failed && selector.closed?
          puts "ok"
        RUBY

        assert_predicate status, :success?, error
        assert_equal "ok\n", output
      end

      def test_selector_inside_another_ractor_and_control_cleanup
        output, error, status = ruby_subprocess(<<~RUBY)
          require "farce"
          require "timeout"
          internal = Farce.const_get(:Internal)
          internal::FiberScheduler
          Farce::Scheduler
          baseline = Ractor.count
          worker = Ractor.new do
            handle = Farce::Scheduler.new
            Fiber.set_scheduler(handle)
            scheduler = Fiber.scheduler
            result = nil
            Fiber.schedule { result = Farce::Ractor.receive(timeout: 1) }
            Fiber.schedule { Ractor.current.send(:ready) }
            handle.close
            scheduler.run
            result
          ensure
            Fiber.set_scheduler(nil)
          end
          result = RUBY_VERSION >= "4" ? worker.value : worker.take
          raise "wrong result" unless result == :ready
          Timeout.timeout(5) { Thread.pass until Ractor.count <= baseline }
          puts "ok"
        RUBY

        assert_predicate status, :success?, error
        assert_equal "ok\n", output
      end

      def test_legacy_select_can_yield_without_blocking_other_fibers
        return unless RUBY_VERSION < "4"
        output, error, status = ruby_subprocess(<<~RUBY)
          require "farce"
          Farce.const_get(:Internal)::FiberScheduler
          Farce::Scheduler
          worker = Ractor.new do
            handle = Farce::Scheduler.new
            Fiber.set_scheduler(handle)
            scheduler = Fiber.scheduler
            events = []
            Fiber.schedule { events << Ractor.select(yield_value: :outgoing) }
            Fiber.schedule { events << :progress }
            handle.close
            scheduler.run
            events
          ensure
            Fiber.set_scheduler(nil)
          end
          raise "wrong yield" unless worker.take == :outgoing
          events = worker.take
          raise events.inspect unless events.include?(:progress) && events.include?([:yield, nil])
          puts "ok"
        RUBY

        assert_predicate status, :success?, error
        assert_equal "ok\n", output
      end

      def test_legacy_selector_progresses_during_gc_and_nested_thread_completion
        return unless RUBY_VERSION < "4"
        output, error, status = ruby_subprocess(<<~RUBY, timeout: 30)
          require "farce"
          handle = Farce::Scheduler.new
          Fiber.set_scheduler(handle)
          scheduler = Fiber.scheduler
          Fiber.schedule do
            300.times do
              worker = Ractor.new { Thread.new { Ractor.current }.value; [:ok] }
              raise "wrong result" unless worker.take == [:ok]
              GC.start
            end
          end
          handle.close
          scheduler.run
          Fiber.set_scheduler(nil)
          puts "ok"
        RUBY

        assert_predicate status, :success?, error
        assert_equal "ok\n", output
      end

      def test_native_timeout_support_and_visibility_are_preserved
        output, error, status = ruby_subprocess(<<~RUBY)
          methods = [[Ractor.singleton_class, :select], [Ractor.singleton_class, :receive]]
          %i[receive recv join value take].each do |method|
            methods << [Ractor, method] if Ractor.method_defined?(method) || Ractor.private_method_defined?(method)
          end
          methods << [Ractor::Port, :receive] if Ractor.const_defined?(:Port, false)
          contracts = -> { methods.map { |owner, name| owner.private_method_defined?(name) } }
          before = contracts.call
          errors = -> do
            calls = [-> { Ractor.receive(timeout: 0) }, -> { Ractor.select(Ractor.current, timeout: 0) }]
            calls << -> { Ractor::Port.new.receive(timeout: 0) } if Ractor.const_defined?(:Port, false)
            calls.map do |call|
              call.call
              nil
            rescue ArgumentError => error
              [error.class, error.message]
            end
          end
          native_errors = errors.call if RUBY_VERSION < "4.1"
          setter = Fiber.method(:set_scheduler)
          require "farce"
          raise "native API changed" unless before == contracts.call
          raise "Fiber.set_scheduler patched" unless setter == Fiber.method(:set_scheduler)
          raise "recv is public" unless Ractor.private_method_defined?(:recv)
          if native_errors
            raise "native errors changed" unless errors.call == native_errors
            scheduler = Class.new do
              def block(*) = nil
              def unblock(*) = nil
              def kernel_sleep(*) = nil
              def io_wait(*) = nil
              def ractor_selector = raise("invalid timeout consulted the selector")
            end.new
            Fiber.set_scheduler(scheduler)
            Fiber.new(blocking: false) do
              raise "native errors changed with a scheduler" unless errors.call == native_errors
            end.resume
            Fiber.set_scheduler(nil)
          end
          puts "ok"
        RUBY

        assert_predicate status, :success?, error
        assert_equal "ok\n", output
      end

      def test_synchronous_native_operations_do_not_start_a_selector
        output, error, status = ruby_subprocess(<<~RUBY)
          require "farce"
          internal = Farce.const_get(:Internal)
          worker = Ractor.new { :ready }
          raise "wrong value" unless Farce::Ractor.select(worker) == [worker, :ready]
          if RUBY_VERSION >= "4.1"
            port = Ractor::Port.new
            raise "wrong timeout" unless port.receive(timeout: 0).nil?
            raise "wrong timeout" unless Farce::Port.new.receive(timeout: 0).nil?
            raise "wrong timeout" unless Farce::Ractor.select(port, timeout: 0).nil?
            port.close
          end
          raise "selector started" if internal::Storage[internal::RactorSelector]
          puts "ok"
        RUBY

        assert_predicate status, :success?, error
        assert_equal "ok\n", output
      end

      def test_native_waits_do_not_opt_in_with_async
        output, error, status = ruby_subprocess(<<~RUBY)
          require "async"
          require "farce"
          internal = Farce.const_get(:Internal)
          selector = internal::RactorSelector
          selector.define_singleton_method(:current) { raise "native wait started a selector" }
          selector.define_singleton_method(:for_call) { |*| raise "native wait consulted Farce dispatch" }
          Async do
            raise "no scheduler" unless Fiber.scheduler
            owner = Ractor.current
            sender = Thread.new { owner.send(:inbox) }
            raise "wrong receive" unless Ractor.receive == :inbox
            sender.join
            worker = Ractor.new { :selected }
            raise "wrong select" unless Ractor.select(worker) == [worker, :selected]
            worker = Ractor.new { :value }
            value = RUBY_VERSION >= "4" ? worker.value : worker.take
            raise "wrong value" unless value == :value
            if RUBY_VERSION >= "4"
              Ractor.new {}.join
              port = Ractor::Port.new
              sender = Thread.new { port.send(:native) }
              raise "wrong port result" unless port.receive == :native
              sender.join
              port.close
            end
          end.wait
          puts "ok"
        RUBY

        assert_predicate status, :success?, error
        assert_equal "ok\n", output
      end

      def test_farce_apis_opt_in_with_async
        output, error, status = ruby_subprocess(<<~RUBY)
          require "async"
          require "farce"
          input = Farce::Port.new
          Async do |task|
            result = nil
            task.async { result = input.receive }
            task.async { input.send(:message) }
            task.children.each(&:wait)
            raise "wrong receive" unless result == :message
            task.async { result = Farce::Ractor.select(input) }
            task.async { input.send(:selected) }
            task.children.each(&:wait)
            raise "wrong select" unless result == [input, :selected]
          end.wait
          input.close
          puts "ok"
        RUBY

        assert_predicate status, :success?, error
        assert_equal "ok\n", output
      end

      def test_wrapping_async_does_not_opt_in_native_waits
        output, error, status = ruby_subprocess(<<~RUBY)
          require "async"
          require "farce"
          internal = Farce.const_get(:Internal)
          internal::RactorSelector.define_singleton_method(:current) { raise "wrapper started a selector" }
          result = nil
          owner = Ractor.current
          started = Thread::Queue.new
          sender = Thread.new { started.pop; owner.send(:message) }
          Async do
            handle = Farce::Scheduler.current
            handle.schedule do
              started << true
              result = Ractor.receive
            end
            handle.close
          end.wait
          sender.join
          raise "Farce task did not complete" unless result == :message
          puts "ok"
        RUBY

        assert_predicate status, :success?, error
        assert_equal "ok\n", output
      end

      def test_an_external_scheduler_can_explicitly_provide_a_selector
        output, error, status = ruby_subprocess(<<~RUBY)
          require "async"
          require "farce"
          internal = Farce.const_get(:Internal)
          result = nil
          Async do |task|
            Fiber.scheduler.define_singleton_method(:ractor_selector) { internal::RactorSelector.current }
            task.async { result = Ractor.receive }
            task.async { Ractor.current.send(:message) }
            task.children.each(&:wait)
          end.wait
          raise "native receive did not cooperate" unless result == :message
          puts "ok"
        RUBY

        assert_predicate status, :success?, error
        assert_equal "ok\n", output
      end

      def test_builtin_scheduler_initializes_selector_only_when_needed
        output, error, status = ruby_subprocess(<<~RUBY)
          require "farce"
          internal = Farce.const_get(:Internal)
          handle = Farce::Scheduler.new
          Fiber.set_scheduler(handle)
          scheduler = Fiber.scheduler
          Fiber.schedule { 1 + 1 }
          existing = internal::Storage[internal::RactorSelector]
          if RUBY_VERSION >= "4"
            raise "selector initialized eagerly" if existing
          else
            raise "3.4 control Ractor was not initialized" unless existing
          end
          result = nil
          Fiber.schedule { result = Ractor.receive }
          Fiber.schedule { Ractor.current.send(:message) }
          handle.close
          scheduler.run
          raise "native receive did not cooperate" unless result == :message
          raise "selector not reused" unless scheduler.ractor_selector.equal?(internal::RactorSelector.current)
          Fiber.set_scheduler(nil)
          puts "ok"
        RUBY

        assert_predicate status, :success?, error
        assert_equal "ok\n", output
      end

      def test_invalid_timeout
        input = port

        assert_raises(ArgumentError) { input.receive(timeout: -1) }
        assert_raises(RangeError) { RactorSelector.current.ractor_receive(input, timeout: Float::NAN) }
      end
    end
  end
end
