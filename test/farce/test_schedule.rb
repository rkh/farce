# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestSchedule < Test
    include Helpers::InternalTestHelpers

    class OptionsScheduler < Helpers::QueueTestScheduler
      attr_reader :options

      def fiber(**options, &)
        @options = options
        super(&)
      end
    end

    def teardown
      Fiber.set_scheduler(nil) if Fiber.respond_to?(:scheduler) && Fiber.scheduler
    end

    def test_default_scheduling_preserves_local_arguments_and_binding
      source = []
      completed = Queue.new
      caller_self = self
      returned = Farce.schedule(source, :done) do |array, value|
        array << value
        completed << [array.equal?(source), equal?(caller_self), Ractor.main?]
      end

      assert_nil returned
      assert_equal [true, true, true], completed.pop(timeout: 5)
      assert_equal [:done], source
    end

    def test_explicit_local_mode_overrides_auto_local_false
      source = []
      completed = Queue.new
      returned = Farce.schedule(source, mode: :local, auto_local: false) do |array|
        array << :done
        completed << array.equal?(source)
      end

      assert_nil returned
      assert completed.pop(timeout: 5)
      assert_equal [:done], source
    end

    def test_returns_before_the_task_finishes
      events = Queue.new
      release = Queue.new
      submitter = Thread.new do
        Farce.schedule do
          events << :started
          release.pop
          events << :finished
        end
      end

      assert_equal :started, events.pop(timeout: 5)
      assert submitter.join(5), "schedule waited for the task to finish"
      assert_nil submitter.value
      assert_nil events.try_pop
      release << :continue

      assert_equal :finished, events.pop(timeout: 5)
    ensure
      release&.close
      submitter&.kill&.join
    end

    def test_auto_local_false_uses_parallel_argument_transfer
      source = [:original]
      completed = Queue.new
      returned = Farce.schedule(source, completed, auto_local: false) do |array, output|
        array << :changed
        output << Ractor.main?
      end

      assert_nil returned
      assert_equal !Ractor.builtin?, completed.pop(timeout: 5)
      assert_equal Ractor.builtin? ? [:original] : %i[original changed], source
    end

    def test_explicit_transfer_mode_is_forwarded
      source = [:original]
      completed = Queue.new
      Farce.schedule(source, completed, mode: :make_shareable, auto_local: false) do |array, output|
        output << array.frozen?
      end

      assert_equal Ractor.builtin?, completed.pop(timeout: 5)
      assert_equal Ractor.builtin?, source.frozen?
    end

    def test_current_fiber_scheduler_preserves_arguments_binding_and_thread
      return unless Fiber.respond_to?(:set_scheduler)
      Fiber.set_scheduler(Helpers::QueueTestScheduler.new)
      source = []
      caller_self = self
      caller_thread = Internal.storage_thread(Thread.current)
      caller_fiber = Fiber.current
      observed = nil
      returned = Farce.schedule(source, nil, false, mode: :move) do |array, *values|
        array.concat(values)
        observed = [array, self, Internal.storage_thread(Thread.current), Fiber.current]
      end

      assert_nil returned
      assert_same source, observed[0]
      assert_same caller_self, observed[1]
      assert_same caller_thread, observed[2]
      refute_same caller_fiber, observed[3]
      assert_equal [nil, false], source
    end

    def test_explicit_local_mode_uses_the_current_fiber_scheduler
      return unless Fiber.respond_to?(:set_scheduler)
      Fiber.set_scheduler(Helpers::QueueTestScheduler.new)
      caller_thread = Internal.storage_thread(Thread.current)
      observed = nil
      returned = Farce.schedule(mode: :local, auto_local: false) { observed = Internal.storage_thread(Thread.current) }

      assert_nil returned
      assert_same caller_thread, observed
    end

    def test_auto_local_false_bypasses_the_current_fiber_scheduler
      return unless Fiber.respond_to?(:set_scheduler)
      scheduler = OptionsScheduler.new
      Fiber.set_scheduler(scheduler)
      completed = Queue.new
      Farce.schedule(completed, auto_local: false) { |output| output << :done }

      assert_equal :done, completed.pop(timeout: 5)
      assert_nil scheduler.options
    end

    def test_fiber_scheduler_receives_keyword_options
      return unless Fiber.respond_to?(:set_scheduler)
      scheduler = OptionsScheduler.new
      Fiber.set_scheduler(scheduler)
      arguments = nil
      returned = Farce.schedule(:argument, priority: :low) { |*values| arguments = values }

      assert_nil returned
      assert_equal({ priority: :low }, scheduler.options)
      assert_equal [:argument], arguments
    end

    def test_fiber_task_can_suspend_until_another_task_runs
      return unless Fiber.respond_to?(:set_scheduler)
      Fiber.set_scheduler(Helpers::QueueTestScheduler.new)
      queue = Queue.new
      events = []

      assert_nil(Farce.schedule do
        events << :started
        events << queue.pop
      end)
      assert_equal [:started], events
      assert_nil(Farce.schedule { queue << :finished })
      Fiber.set_scheduler(nil)

      assert_equal %i[started finished], events
    end

    def test_missing_block_is_rejected_before_fiber_submission
      return unless Fiber.respond_to?(:set_scheduler)
      scheduler = OptionsScheduler.new
      Fiber.set_scheduler(scheduler)

      assert_raises(LocalJumpError) { Farce.schedule }
      assert_nil scheduler.options
    end

    def test_missing_block_does_not_start_background_schedulers
      output, error, status = ruby_subprocess(<<~RUBY)
        require "farce"
        internal = Farce.const_get(:Internal)
        [ {}, { auto_local: false }, { mode: :local } ].each do |options|
          begin
            Farce.schedule(**options)
            abort "accepted a missing block"
          rescue LocalJumpError
          end
        end
        abort "started parallel scheduler" unless internal.autoload?(:ParallelScheduler)
        if Farce::Ractor.builtin?
          abort "started main scheduler" unless internal.autoload?(:MainScheduler)
        end
        puts "rejected"
      RUBY

      assert_predicate status, :success?, error
      assert_equal "rejected\n", output
      assert_empty error
    end

    def test_default_scheduling_in_a_ractor_uses_parallel_fallback
      completed = Queue.new
      caller = Ractor.new(completed) do |output|
        internal = Farce.const_get(:Internal)
        Farce.schedule(output) { |queue| queue << Ractor.current }
        cached = internal::Storage[:local_scheduler]
        Ractor.receive
        cached.nil?
      end

      task_owner = completed.pop(timeout: 5)

      refute_nil task_owner
      if Ractor.builtin?
        refute_same caller, task_owner
        refute_same Ractor.main, task_owner
      else
        assert_same caller, task_owner
      end
      caller.send(:stop)

      assert ractor_value(caller)
    end

    def test_local_scheduling_in_a_ractor_creates_and_reuses_a_local_scheduler
      assert_ractor_local_scheduling("Farce::Ractor")
    end

    def test_first_local_schedule_from_a_ractor_needs_no_prior_setup
      assert_ractor_local_scheduling("Farce::Ractor", freeze_config: false)
    end

    def test_local_scheduling_in_a_native_ractor
      return unless Ractor.builtin?

      assert_ractor_local_scheduling("::Ractor", freeze_config: false)
    end

    private

    def assert_ractor_local_scheduling(constructor, freeze_config: true)
      output, error, status = ruby_subprocess(<<~RUBY, timeout: 30)
        require "farce"
        #{"Farce.config.freeze" if freeze_config}
        caller = #{constructor}.new do
          internal = Farce.const_get(:Internal)
          source = []
          completed = Farce::Queue.new
          modes = [ { mode: :local, auto_local: false }, { mode: :local }, {} ]
          scheduler = nil
          modes.each_with_index do |options, index|
            returned = Farce.schedule(source, **options) do |array|
              array << index
              completed << [array.equal?(source), Farce::Ractor.current]
            end
            abort "wrong return value" unless returned.nil?
            result = completed.pop(timeout: 5)
            abort "task did not stay local" unless result == [true, Farce::Ractor.current]
            current = internal::Storage[:local_scheduler]
            abort "scheduler was not cached" unless current
            abort "scheduler was replaced" if scheduler && !scheduler.equal?(current)
            scheduler = current
          end
          abort "arguments were copied" unless source == [0, 1, 2]
          :done
        ensure
          scheduler ||= internal::Storage[:local_scheduler]
          if scheduler && !scheduler.is_a?(Farce::ThreadScheduler)
            scheduler.close
            Thread.pass until scheduler.state == :closed
          end
        end
        result = caller.respond_to?(:value) ? caller.value : caller.take
        abort "caller did not finish" unless result == :done
        puts "local"
      RUBY

      assert_predicate status, :success?, error
      assert_equal "local\n", output
      assert_empty error
    end
  end
end
