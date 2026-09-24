# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestOnMain < Test
    include Helpers::InternalTestHelpers

    def test_ractor_creation_and_local_calls_leave_the_main_scheduler_unloaded
      return unless Ractor.builtin?
      output, error, status = ruby_isolated(<<~RUBY)
        require "farce"
        abort "loaded on require" unless Farce.const_get(:Internal).autoload?(:MainScheduler)
        Farce.on_main { :local }
        abort "loaded on local call" unless Farce.const_get(:Internal).autoload?(:MainScheduler)
        worker = Farce::Ractor.new { :done }
        worker.respond_to?(:value) ? worker.value : worker.take
        abort "loaded on ractor creation" unless Farce.const_get(:Internal).autoload?(:MainScheduler)
        if Farce::Ractor.builtin?
          worker = ::Ractor.new { :done }
          worker.respond_to?(:value) ? worker.value : worker.take
          abort "loaded on native ractor creation" unless Farce.const_get(:Internal).autoload?(:MainScheduler)
        end
        puts "lazy"
      RUBY

      assert_predicate status, :success?, error
      assert_equal "lazy\n", output
      assert_empty error
    end

    def test_including_farce_does_not_expose_or_start_the_main_scheduler
      output, error, status = ruby_isolated(<<~RUBY)
        require "farce"
        namespace = Module.new { include Farce }
        abort "public scheduler constant" if Farce.const_defined?(:MainScheduler, false)
        abort "included scheduler constant" if namespace.const_defined?(:MainScheduler, false)
        if Farce::Ractor.builtin?
          abort "scheduler started by include" unless Farce.const_get(:Internal).autoload?(:MainScheduler)
        else
          abort "wrong scheduler" unless Farce.on_main.is_a?(Farce::ThreadScheduler)
        end
        puts "internal"
      RUBY

      assert_predicate status, :success?, error
      assert_equal "internal\n", output
      assert_empty error
    end

    def test_without_a_block_returns_the_main_scheduler
      assert_same Farce.on_main, Farce.on_main
      if Ractor.builtin?
        assert_same Ractor.main, Farce.on_main.owner
      else
        assert_instance_of ThreadScheduler, Farce.on_main
      end
    end

    def test_arguments_without_a_block_are_rejected
      [[:argument], [nil], [false], [nil, false]].each do |args|
        assert_raises(LocalJumpError) { Farce.on_main(*args) }
      end
      assert_raises(LocalJumpError) { Farce.on_main(mode: :copy) }
    end

    def test_local_execution_preserves_arguments_binding_and_fiber
      values = []
      caller_self = self
      caller_fiber = Fiber.current
      result = Farce.on_main(values, :done) do |array, value|
        assert_same values, array
        assert_same caller_self, self
        assert_same caller_fiber, Fiber.current
        array << value
      end

      assert_nil result
      assert_equal [:done], values
    end

    def test_local_execution_without_arguments
      called = false

      assert_nil(Farce.on_main { called = true })
      assert called
    end

    def test_local_execution_does_not_transfer_arguments
      values = []
      Farce.on_main(values, mode: :move) { |array| array << :done }

      assert_equal [:done], values
    end

    def test_local_execution_propagates_exceptions
      failure = ArgumentError.new("task failed")

      assert_same failure, assert_raises(ArgumentError) { Farce.on_main { raise failure } }
    end

    def test_execution_from_a_main_ractor_thread_stays_on_that_thread
      worker = Thread.new do
        caller_thread = Thread.current
        same_thread = false
        Farce.on_main { same_thread = Thread.current.equal?(caller_thread) }
        same_thread
      end

      assert worker.value
    end

    def test_remote_execution_waits_for_completion
      Farce.on_main
      events = Queue.new
      release = Queue.new
      remote = Ractor.new(events, release) do |output, gate|
        returned = Farce.on_main(output, gate) do |result, ready|
          result << [:started, Ractor.main?]
          ready.pop
          result << :finished
        end
        output << [:returned, returned]
      end

      assert_equal [:started, Ractor.builtin?], events.pop(timeout: 5)
      assert_nil events.try_pop
      release << :continue

      assert_equal :finished, events.pop(timeout: 5)
      assert_equal [:returned, nil], events.pop(timeout: 5)
    ensure
      release&.close
      ractor_value(remote) if remote
    end

    def test_remote_execution_copies_mutable_arguments_by_default
      Farce.on_main
      completed = Queue.new
      remote = Ractor.new(completed) do |ready|
        source = [:original]
        Farce.on_main(source) { |array| array << :changed }
        ready << true
        source
      end

      assert completed.pop(timeout: 5)
      expected = Internal.native_ractors? ? [:original] : %i[original changed]

      assert_equal expected, ractor_value(remote)
    end

    def test_remote_execution_honors_the_transfer_mode
      return unless Internal.native_ractors?
      Farce.on_main
      remote = Ractor.new do
        source = [:original]
        Farce.on_main(source, mode: :make_shareable, &:first)
        [source.frozen?, Ractor.shareable?(source)]
      end

      assert_equal [true, true], ractor_value(remote)
    end

    def test_first_use_from_another_ractor_executes_on_main
      assert_cold_remote_call <<~RUBY
        Farce.on_main("done") { |value| $on_main_results << value }
      RUBY
    end

    def test_first_use_from_another_ractor_returns_a_nonblocking_scheduler
      assert_cold_remote_call <<~RUBY
        scheduler = Farce.on_main
        if Farce::Ractor.builtin?
          abort "wrong owner" unless scheduler.owner == Farce::Ractor.main
        end
        events = Farce::Queue.new
        release = Farce::Queue.new
        scheduler.schedule(events, release) do |output, gate|
          output << :started
          gate.pop
          $on_main_results << "done"
          output << :finished
        end
        abort "task did not start" unless events.pop(timeout: 5) == :started
        release << :continue
        abort "task did not finish" unless events.pop(timeout: 5) == :finished
      RUBY
    end

    def test_first_use_from_a_native_ractor_executes_on_main
      return unless Internal.native_ractors?

      assert_cold_remote_call(<<~RUBY, constructor: "::Ractor")
        Farce.on_main("done") { |value| $on_main_results << value }
      RUBY
    end

    def test_first_use_from_a_native_ractor_returns_the_scheduler
      return unless Internal.native_ractors?

      assert_cold_remote_call(<<~RUBY, constructor: "::Ractor")
        scheduler = Farce.on_main
        scheduler.execute("done") { |value| $on_main_results << value }
      RUBY
    end

    private

    def assert_cold_remote_call(source, constructor: "Farce::Ractor")
      output, error, status = ruby_isolated(<<~RUBY, timeout: 30)
        require "farce"
        require "timeout"
        $on_main_results = []
        completed = Farce.const_get(:Internal)::Queue.new
        remote = #{constructor}.new(completed) do |ready|
          if Farce::Ractor.builtin?
            abort "scheduler loaded before use" unless Farce.const_get(:Internal).autoload?(:MainScheduler)
          end
          #{source}
          ready.push(true)
        end
        # Ruby 3.4 can lose a take wakeup when another thread uses Ractor.select.
        # Wait until copying on the scheduler has finished before taking the result.
        abort "caller did not finish" unless completed.pop(timeout: 5)
        remote.respond_to?(:value) ? remote.value : remote.take
        abort "task did not run" unless $on_main_results == ["done"]
        if Farce::Ractor.builtin?
          abort "wrong owner" unless Farce.on_main.owner == Farce::Ractor.main
        end
        Farce.on_main.schedule(completed) { |ready| ready.push(Farce::Ractor.main?) }
        abort "scheduler stopped with caller" unless completed.pop(timeout: 5)
        if Farce::Ractor.builtin?
          Farce.on_main.close
          Timeout.timeout(5) { Thread.pass until Farce.on_main.state == :closed }
        end
        puts "done"
      RUBY
      assert_predicate status, :success?, error
      assert_equal "done\n", output
      assert_empty error
    end
  end
end
