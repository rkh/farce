# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestInParallel < Test
    def test_returns_one_shared_scheduler
      scheduler = Farce.in_parallel

      assert_same scheduler, Farce.in_parallel
      assert Ractor.shareable?(scheduler)
      if Ractor.builtin?
        assert_instance_of Pool, scheduler
        assert_equal System.cpu_count, scheduler.max_size
      else
        assert_instance_of ThreadScheduler, scheduler
        assert_same Farce.on_main, scheduler
      end
    end

    def test_arguments_without_a_block_are_rejected
      [[:argument], [nil], [false], [nil, false]].each do |args|
        assert_raises(LocalJumpError) { Farce.in_parallel(*args) }
      end
      assert_raises(LocalJumpError) { Farce.in_parallel(mode: :copy) }
    end

    def test_returns_before_the_task_finishes
      events = Queue.new
      release = Queue.new
      submitter = Thread.new do
        Farce.in_parallel(events, release) do |output, gate|
          output << :started
          gate.pop
          output << :finished
        end
      end

      assert_equal :started, events.pop(timeout: 5)
      assert submitter.join(5), "in_parallel waited for the task to finish"
      assert_nil submitter.value
      assert_nil events.try_pop
      release << :continue

      assert_equal :finished, events.pop(timeout: 5)
    ensure
      release&.close
      submitter&.kill&.join
    end

    def test_block_without_arguments
      assert_nil(Farce.in_parallel { :done })
    end

    def test_default_argument_transfer
      source = [:original]
      finished = Queue.new
      Farce.in_parallel(source, finished) do |array, output|
        array << :changed
        output << :done
      end

      assert_equal :done, finished.pop(timeout: 5)
      assert_equal Ractor.builtin? ? [:original] : %i[original changed], source
    end

    def test_explicit_argument_transfer
      source = [:original]
      finished = Queue.new
      Farce.in_parallel(source, finished, mode: :make_shareable) do |array, output|
        output << array.frozen?
      end

      assert_equal Ractor.builtin?, finished.pop(timeout: 5)
      assert_equal Ractor.builtin?, source.frozen?
    end

    def test_require_and_include_leave_the_scheduler_internal_and_unloaded
      output, error, status = ruby_isolated(<<~RUBY)
        require "farce"
        internal = Farce.const_get(:Internal)
        abort "loaded during require" unless internal.autoload?(:ParallelScheduler)
        abort "configuration frozen" if Farce.config.frozen?
        namespace = Module.new { include Farce }
        abort "public scheduler" if Farce.const_defined?(:ParallelScheduler, false)
        abort "included scheduler" if namespace.const_defined?(:ParallelScheduler, false)
        abort "loaded during include" unless internal.autoload?(:ParallelScheduler)
        scheduler = Farce.in_parallel
        if Farce::Ractor.builtin?
          abort "workers started without work" unless scheduler.size.zero?
          scheduler.close
        end
        puts "lazy"
      RUBY

      assert_predicate status, :success?, error
      assert_equal "lazy\n", output
      assert_empty error
    end

    def test_first_use_from_a_ractor
      assert_remote_first_use("Farce::Ractor")
    end

    def test_first_use_from_a_native_ractor
      return unless Ractor.builtin?

      assert_remote_first_use("::Ractor")
    end

    private

    def assert_remote_first_use(constructor)
      output, error, status = ruby_isolated(<<~RUBY, timeout: 30)
        require "farce"
        require "timeout"
        events = Farce::Queue.new
        caller = #{constructor}.new(events) do |output|
          scheduler = Farce.in_parallel
          output << scheduler
          Farce.in_parallel(output) { |queue| queue << [:done, Farce::Ractor.main?] }
          # Keep a shim Ractor alive until its task thread has completed.
          Farce::Ractor.receive
          :finished
        end
        scheduler = events.pop(timeout: 5)
        abort "scheduler is not shared" unless scheduler.equal?(Farce.in_parallel)
        result = events.pop(timeout: 5)
        abort "task did not run off main" unless result == [:done, false]
        caller.send(:stop)
        result = caller.respond_to?(:value) ? caller.value : caller.take
        abort "caller did not finish" unless result == :finished
        if Farce::Ractor.builtin?
          scheduler.close
          Timeout.timeout(5) { Thread.pass until scheduler.state == :closed }
        end
        puts "done"
      RUBY

      assert_predicate status, :success?, error
      assert_equal "done\n", output
      assert_empty error
    end
  end
end
