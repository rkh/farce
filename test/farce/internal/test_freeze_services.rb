# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../../setup"

module Farce
  module Internal
    class TestFreezeServices < Test
      def test_native_service_rejection_keeps_services_live
        queue = Queue.new
        priority_queue = PriorityQueue.new
        signal = Signal.new
        exchanger = Exchanger.new

        [queue, priority_queue, signal, exchanger].each { assert_freeze_rejected(it) }

        assert queue.push(:queued)
        assert_equal :queued, queue.pop

        assert priority_queue.push(1, :prioritized)
        assert_equal :prioritized, priority_queue.pop

        generation = signal.generation

        assert_operator signal.broadcast, :>, generation

        first = Thread.new { exchanger.exchange(:first) }
        second = Thread.new { exchanger.exchange(:second) }

        assert_equal :second, first.value
        assert_equal :first, second.value
      ensure
        queue&.close
        priority_queue&.close
      end

      def test_owned_lock_rejection_keeps_synchronization_live
        return if Internal::Lock.equal?(::Mutex)

        lock = Internal::Lock.new

        assert_freeze_rejected(lock)
        assert_equal(:locked, lock.synchronize { :locked })
      end

      def test_ruby_coordination_services_reject_freeze_and_remain_live
        locks = KeyLockMap.new(registry_class: Strict::Map)
        ordered_locks = OrderedKeyLockMap.new
        pool = Pool.new(max_size: 1, shrink_after: nil)
        worker = PoolWorker.new(pool)

        [locks, ordered_locks, worker, PoolSupervisor].each { assert_freeze_rejected(it) }

        assert_equal(:locked, locks.synchronize(:key) { :locked })
        assert_equal(:ordered, ordered_locks.synchronize(:key) { :ordered })
        worker.task_started
        worker.task_finished
      ensure
        pool&.close
      end

      def test_owned_internal_port_rejects_freeze_and_remains_live
        return if defined?(::Ractor::Port) && Internal::Port.equal?(::Ractor::Port)

        port = Internal::Port.new

        assert_freeze_rejected(port)
        assert_same port, port.send(:message)
        assert_equal :message, port.receive
      ensure
        port&.close
      end

      def test_public_port_adapter_is_structurally_published_before_rejecting_freeze
        return unless RUBY_ENGINE == "ruby" && RUBY_VERSION.start_with?("3.4")

        port = Farce::Port.new

        assert Object.instance_method(:frozen?).bind_call(port)
        assert Ractor.shareable?(port)
        assert_freeze_rejected(port)
        assert_same port, port.send(:message)
        assert_equal :message, port.receive
      ensure
        port&.close
      end

      private

      def assert_freeze_rejected(object)
        refute_predicate object, :frozen?
        assert_raises(TypeError) { object.freeze }
        refute_predicate object, :frozen?
      end
    end
  end
end
