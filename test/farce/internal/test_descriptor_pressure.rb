# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../../setup"

module Farce
  module Internal
    class TestDescriptorPressure < Test
      SETUP = <<~RUBY
        require "farce"
        require "helpers/queue_test_scheduler"

        internal = Farce.const_get(:Internal)
        NativeQueue = internal::Queue
        NativeAtom = internal::Atom
        Process.setrlimit(:NOFILE, [256, Process.getrlimit(:NOFILE).last].min)

        def exhaust_descriptors
          files = []
          loop { files << File.open(File::NULL) }
        rescue Errno::EMFILE
          files
        end
      RUBY

      def test_garbage_collection_recovers_discarded_queue_pipes
        assert_pressure_probe(<<~RUBY)
          GC.disable
          before = GC.stat(:count)
          400.times do
            queue = NativeQueue.new
            queue.pop(timeout: 0.001)
            queue = nil
          end
          raise "descriptor pressure did not collect" unless GC.stat(:count) > before
          GC.enable
        RUBY
      end

      def test_fiber_waits_poll_cooperatively_when_pipes_cannot_be_created
        assert_pressure_probe(<<~'RUBY')
          operations = [
            [:pop, ->(queue) { queue.pop }, ->(queue) { queue.push(:ready) }, :ready],
            [:wait_pop, ->(queue) { queue.wait_pop }, ->(queue) { queue.push(:ready) }, true],
            [:push, ->(queue) { queue.push(:ready) }, ->(queue) { queue.pop }, true],
            [:wait_push, ->(queue) { queue.wait_push }, ->(queue) { queue.pop }, true],
            [:changed, ->(atom) { atom.wait_until_changed(nil) }, ->(atom) { atom.value = :ready }, :ready],
            [:non_nil, ->(atom) { atom.wait_until_non_nil }, ->(atom) { atom.value = :ready }, :ready],
          ]
          operations.each do |name, wait, notify, expected|
            scheduler = Helpers::QueueTestScheduler.new
            target = [:changed, :non_nil].include?(name) ? NativeAtom.new : NativeQueue.new(capacity: 1)
            target.push(:full) if [:push, :wait_push].include?(name)
            files = exhaust_descriptors
            Fiber.set_scheduler(scheduler)
            result = nil
            Fiber.schedule { result = wait.call(target) }
            if target.is_a?(NativeQueue)
              raise "polling waiter was not counted" unless target.num_waiting == 1
            end
            Fiber.schedule { notify.call(target) }
            Fiber.set_scheduler(nil)
            raise "wrong result for #{name}: #{result.inspect}" unless result == expected
            raise "fallback did not yield for #{name}" unless scheduler.block_calls.positive?
            raise "fallback used IO for #{name}" unless scheduler.io_wait_calls.zero?
            raise "waiter retained for #{name}" if target.is_a?(NativeQueue) && target.num_waiting != 0
            files.each(&:close)
          end
        RUBY
      end

      def test_queue_falls_back_when_only_descriptor_duplication_fails
        assert_pressure_probe(<<~RUBY)
          scheduler = Helpers::QueueTestScheduler.new
          queue = NativeQueue.new
          queue.pop(timeout: 0.001) # Keep an existing readiness pipe.
          files = exhaust_descriptors
          Fiber.set_scheduler(scheduler)
          result = nil
          Fiber.schedule { result = queue.pop }
          Fiber.schedule { queue.push(:ready) }
          Fiber.set_scheduler(nil)
          raise "wrong result" unless result == :ready
          raise "duplication fallback did not yield" unless scheduler.block_calls.positive?
          raise "duplication fallback used IO" unless scheduler.io_wait_calls.zero?
          files.each(&:close)
        RUBY
      end

      def test_polling_preserves_timeouts_and_timeout_blocks
        assert_pressure_probe(<<~RUBY)
          queue = NativeQueue.new(capacity: 1)
          atom = NativeAtom.new
          files = exhaust_descriptors
          started = Farce::Clock.now
          raise "queue timeout block lost" unless queue.pop(timeout: 0.01) { :expired } == :expired
          raise "atom timeout block lost" unless atom.wait_until_non_nil(timeout: 0.01) { :expired } == :expired
          raise "atom changed timeout lost" unless atom.wait_until_changed(nil, timeout: 0).nil?
          queue.push(:full)
          raise "push timeout lost" if queue.wait_push(timeout: 0.01)
          raise "timeouts returned too early" if Farce::Clock.now - started < 0.03
          raise "polling waiter retained" unless queue.num_waiting.zero?
          files.each(&:close)
        RUBY
      end

      def test_close_and_thread_cancellation_unwind_polling_waiters
        assert_pressure_probe(<<~RUBY)
          queue = NativeQueue.new
          entered = Thread::Queue.new
          gate = Thread::Queue.new
          worker = Thread.new do
            entered << true
            gate.pop
            queue.pop
          rescue Farce::ClosedQueueError
            :closed
          end
          entered.pop
          files = exhaust_descriptors
          gate << true
          Thread.pass until queue.num_waiting == 1
          queue.close
          raise "close did not wake polling wait" unless worker.value == :closed
          raise "closed waiter retained" unless queue.num_waiting.zero?
          files.each(&:close)

          queue = NativeQueue.new
          entered = Thread::Queue.new
          gate = Thread::Queue.new
          worker = Thread.new { entered << true; gate.pop; queue.pop }
          entered.pop
          files = exhaust_descriptors
          gate << true
          Thread.pass until queue.num_waiting == 1
          worker.kill.join
          raise "cancelled waiter retained" unless queue.num_waiting.zero?
          queue.push(:after_cancel)
          raise "cancelled wait consumed a value" unless queue.pop == :after_cancel
          files.each(&:close)
        RUBY
      end

      def test_another_ractor_can_release_polling_fibers
        assert_pressure_probe(<<~RUBY)
          scheduler = Helpers::QueueTestScheduler.new
          queue = NativeQueue.new
          atom = NativeAtom.new
          worker = ::Ractor.new(queue, atom) do |remote_queue, remote_atom|
            ::Ractor.receive
            remote_queue.push(:ready)
            remote_atom.value = :changed
            true
          end
          files = exhaust_descriptors
          Fiber.set_scheduler(scheduler)
          queue_result = atom_result = nil
          Fiber.schedule { queue_result = queue.pop }
          Fiber.schedule { atom_result = atom.wait_until_non_nil }
          worker.send(:go)
          Fiber.set_scheduler(nil)
          raise "cross-Ractor queue result lost" unless queue_result == :ready
          raise "cross-Ractor atom result lost" unless atom_result == :changed
          worker.respond_to?(:value) ? worker.value : worker.take
          files.each(&:close)
        RUBY
      end

      def test_scheduler_failure_cleans_up_the_polling_waiter
        assert_pressure_probe(<<~RUBY)
          scheduler = Helpers::QueueTestScheduler.new
          def scheduler.kernel_sleep(*)
            raise "scheduler failed"
          end
          queue = NativeQueue.new
          files = exhaust_descriptors
          Fiber.set_scheduler(scheduler)
          begin
            Fiber.schedule { queue.pop }
            raise "scheduler failure lost"
          rescue RuntimeError => error
            raise unless error.message == "scheduler failed"
          ensure
            Fiber.set_scheduler(nil)
          end
          raise "failed scheduler waiter retained" unless queue.num_waiting.zero?
          files.each(&:close)
          queue.push(:after_failure)
          raise "queue unusable after failure" unless queue.pop == :after_failure
        RUBY
      end

      def test_farce_schedulers_can_run_the_producer_under_descriptor_pressure
        %w[native select].each do |backend|
          assert_pressure_probe(<<~RUBY, env: { "FARCE_FIBER_SCHEDULER" => backend })
            scheduler = internal::FiberScheduler.new
            queue = NativeQueue.new
            atom = NativeAtom.new
            files = exhaust_descriptors
            Fiber.set_scheduler(scheduler)
            result = nil
            Fiber.schedule { result = [queue.pop, atom.wait_until_non_nil] }
            Fiber.schedule { queue.push(:ready); atom.value = :changed }
            Fiber.set_scheduler(nil)
            raise "producer did not run" unless result == [:ready, :changed]
            files.each(&:close)
          RUBY
        end
      end

      def test_waits_return_to_io_when_descriptors_become_available
        assert_pressure_probe(<<~RUBY)
          scheduler = Helpers::QueueTestScheduler.new
          queue = NativeQueue.new
          files = exhaust_descriptors
          scheduler.define_singleton_method(:kernel_sleep) do |duration|
            files.each { |file| file.close unless file.closed? }
            super(duration)
          end
          scheduler.define_singleton_method(:io_wait) do |*arguments|
            queue.push(:ready)
            super(*arguments)
          end
          Fiber.set_scheduler(scheduler)
          result = nil
          Fiber.schedule { result = queue.pop }
          Fiber.set_scheduler(nil)
          raise "wrong result" unless result == :ready
          raise "polling fallback was bypassed" unless scheduler.block_calls.positive?
          raise "wait did not return to IO" unless scheduler.io_wait_calls == 1
          raise "polling waiter retained" unless queue.num_waiting.zero?
        RUBY
      end

      private

      def assert_pressure_probe(source, env: {})
        return unless RUBY_ENGINE == "ruby" && !Gem.win_platform? && Process.const_defined?(:RLIMIT_NOFILE)
        output, error, status = ruby_subprocess("#{SETUP}\n#{source}\nputs 'ok'", coverage: false, env:)

        assert_predicate status, :success?, error
        assert_equal "ok\n", output
      end
    end
  end
end
