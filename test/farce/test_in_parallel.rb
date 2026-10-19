# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestInParallel < Test
    def test_arguments_without_a_block_are_rejected
      [[:argument], [nil], [false], [nil, false]].each do |args|
        assert_raises(LocalJumpError) { Farce.in_parallel(*args) }
      end
      assert_raises(LocalJumpError) { Farce.in_parallel(mode: :copy) }
    end

    def test_tasks_run_outside_the_main_ractor
      completed = Queue.new
      Farce.in_parallel(completed) { |queue| queue << Farce::Ractor.main? }

      ran_on_main = completed.pop(timeout: 5)

      refute_nil ran_on_main, "parallel task did not finish"
      refute ran_on_main
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

    def test_default_argument_transfer_uses_smart_rules
      source = [:original]
      finished = Queue.new
      Farce.in_parallel(source, finished) { |array, output| output << array.frozen? }

      assert_equal Ractor.builtin?, finished.pop(timeout: 5)
      assert_equal Ractor.builtin?, source.frozen?
    end

    def test_copy_argument_transfer
      source = [:original]
      finished = Queue.new
      Farce.in_parallel(source, finished, mode: :copy) do |array, output|
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

    def test_configured_parallel_pool_applies_worker_limits_and_queue_capacity
      output, error, status = ruby_isolated(<<~RUBY)
        require "farce"
        require "timeout"
        Farce.config do |config|
          config.parallel_pool_max_size = 2
          config.parallel_pool_min_size = 1
          config.parallel_pool_max_inflight = 1
          config.parallel_pool_grow_after = 60
          config.parallel_pool_shrink_after = nil
          config.parallel_pool_capacity = 1
        end
        pool = Farce.in_parallel
        if Farce::Ractor.builtin?
          abort "wrong settings" unless [pool.min_size, pool.max_size, pool.max_inflight,
                                         pool.grow_after, pool.shrink_after] == [1, 2, 1, 60, nil]
          abort "minimum workers not started" unless pool.size == 1
          events = Farce::Queue.new
          gate = Farce::Atom.new(false, mode: :raise)
          Farce.in_parallel(events, gate, mode: :raise) do |queue, release|
            queue << :started
            Fiber.new(blocking: true) { release.wait_until_changed(false) }.resume
            queue << :finished
          end
          abort "task did not start" unless events.pop(timeout: 5) == :started
          pool.schedule(events, mode: :raise) { |queue| queue << :queued }
          abort "capacity ignored" unless pool.try_schedule { :extra }.nil?
          gate.value = true
          2.times { abort "task lost" unless events.pop(timeout: 5) }
          abort "growth limit ignored" unless pool.size == 1
          abort "configuration not frozen" unless Farce.config.frozen?
          pool.close
          Timeout.timeout(5) { sleep 0.001 until pool.state == :closed }
          raise pool.error if pool.error
        else
          abort "executor changed" unless pool.is_a?(Farce::ThreadExecutor)
        end
        puts "ok"
      RUBY

      assert_predicate status, :success?, error
      assert_equal "ok\n", output
      assert_empty error
    end

    def test_parallel_pool_can_disable_capacity_and_worker_limits
      output, error, status = ruby_isolated(<<~RUBY)
        require "farce"
        require "timeout"
        Farce.config do |config|
          config.parallel_pool_max_size = 1
          config.parallel_pool_capacity = nil
          config.parallel_pool_max_inflight = nil
          config.parallel_pool_shrink_after = nil
        end
        pool = Farce.in_parallel
        if Farce::Ractor.builtin?
          abort "task limit ignored" unless pool.max_inflight.nil?
          abort "idle timeout ignored" unless pool.shrink_after.nil?
          events = Farce::Queue.new
          gate = Farce::Atom.new(false, mode: :raise)
          pool.schedule(events, gate, mode: :raise) do |queue, release|
            queue << :started
            Fiber.new(blocking: true) { release.wait_until_changed(false) }.resume
          end
          abort "task did not start" unless events.pop(timeout: 5) == :started
          1025.times { abort "queue bounded" unless pool.try_schedule { :done } }
          gate.value = true
          pool.close
          Timeout.timeout(5) { sleep 0.001 until pool.state == :closed }
          raise pool.error if pool.error
        end
        puts "ok"
      RUBY

      assert_predicate status, :success?, error
      assert_equal "ok\n", output
      assert_empty error
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
        Farce.config do |config|
          config.parallel_pool_max_size = 2
          config.parallel_pool_max_inflight = 3
          config.parallel_pool_grow_after = 0.02
          config.parallel_pool_shrink_after = nil
          config.parallel_pool_capacity = 4
        end
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
          abort "remote settings lost" unless [scheduler.min_size, scheduler.max_size, scheduler.max_inflight,
                                              scheduler.grow_after, scheduler.shrink_after] == [0, 2, 3, 0.02, nil]
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
