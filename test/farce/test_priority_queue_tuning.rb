# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "timeout"

module Farce
  class TestPriorityQueueTuning < Test
    ResizeSignal = Data.define(:failure) do
      def broadcast
        raise "resize notification failed" if failure.set?
      end
    end

    def test_storage_resize_preserves_order_and_age
      storage_classes.each do |type|
        queue = type.new(capacity: 4, track_age: true)
        [[2, :last], [1, :first], [1, :second]].each { |priority, value| queue.push(priority, value) }
        generation = queue.generation
        timestamp = queue.oldest_enqueued_at
        queue.capacity = 1

        assert_equal generation, queue.generation
        assert_equal timestamp, queue.oldest_enqueued_at
        refute queue.push(0, :extra)
        assert_equal :first, queue.pop
        refute queue.push(0, :extra)
        assert_equal :second, queue.pop
        refute queue.push(0, :extra)
        assert_equal :last, queue.pop
        assert queue.push(0, :after)
      end
    end

    def test_storage_switches_between_bounded_and_unbounded
      storage_classes.each do |type|
        queue = type.new(capacity: 1)
        queue.push(0, :first)
        queue.capacity = nil

        assert_nil queue.capacity
        4.times { assert queue.push(1, :later) }
        queue.capacity = 2

        assert_equal 2, queue.capacity
        refute queue.push(0, :extra)
        assert_equal :first, queue.pop
        assert_equal Array.new(4, :later), Array.new(4) { queue.pop }
      end
    end

    def test_invalid_storage_capacity_preserves_the_previous_limit
      storage_classes.each do |type|
        queue = type.new(capacity: 2)
        [0, -1].each do |value|
          assert_raises(ArgumentError) { queue.capacity = value }
          assert_equal 2, queue.capacity
        end
        assert_raises(TypeError) { queue.capacity = Object.new }
        assert_equal 2, queue.capacity
      end
    end

    def test_failed_resize_notification_preserves_the_limit
      storage_classes.each do |type|
        failure = Flag.new
        queue = type.new(capacity: 1, signal: ResizeSignal.new(failure))
        failure.set

        assert_raises(RuntimeError) { queue.capacity = 2 }
        assert_equal 1, queue.capacity
        assert_raises(RuntimeError) { queue.capacity = nil }
        assert_equal 1, queue.capacity
        failure.unset
        queue.capacity = 2

        assert_equal 2, queue.capacity
      end
    end

    def test_resize_keeps_sealed_and_closed_storage_unwritable
      storage_classes.each do |type|
        %i[seal close].each do |operation|
          queue = type.new(capacity: 1)
          queue.push(0, :kept)
          queue.public_send(operation)
          queue.capacity = nil

          assert_predicate queue, :sealed?
          assert_raises(ClosedQueueError) { queue.push(0, :extra) }
          if operation == :seal
            assert_equal :kept, queue.pop
            assert_predicate queue, :closed?
          else
            assert_equal 1, queue.size
          end
        end
      end
    end

    def test_storage_capacity_coercion_and_large_jvm_limits
      storage_classes.each do |type|
        queue = type.new(capacity: 1)
        value = Object.new
        def value.to_int = 3

        assert_equal 3, queue.public_send(:capacity=, value)
        assert_equal 3, queue.capacity
        next if Internal.native_ractors?

        huge = 1 << 100
        queue.capacity = huge

        assert_equal huge, queue.capacity
        assert queue.push(0, :value)
      end
    end

    def test_public_variants_resize_and_retain_timer_handles
      public_classes.each do |type|
        queue = type.new(capacity: 2)
        first = enqueue(queue, :first)
        enqueue(queue, :second)
        queue.capacity = 1

        assert_equal 1, queue.capacity
        refute enqueue(queue, :extra, non_block: true)
        if first.is_a?(Abstract::TimerQueue::Entry)
          assert first.delete
          refute first.delete
        else
          assert_equal :first, queue.pop
        end

        refute enqueue(queue, :extra, non_block: true)
        assert_equal :second, queue.pop
        queue.capacity = nil

        assert_nil queue.capacity
        assert enqueue(queue, :unbounded)
        queue.capacity = 3

        assert_equal 3, queue.capacity
        assert_equal :unbounded, queue.pop
      end
    end

    def test_growing_or_removing_the_limit_wakes_a_blocked_producer
      public_classes.each do |type|
        [2, nil].each do |limit|
          queue = type.new(capacity: 1)
          enqueue(queue, :first)
          producer = Thread.new { enqueue(queue, :second) }
          Timeout.timeout(5) { Thread.pass until queue.num_waiting.positive? }
          queue.capacity = limit

          assert producer.join(5), "#{type} producer stayed blocked after resize to #{limit.inspect}"
          assert_equal %i[first second], Array.new(2) { queue.pop }
        ensure
          queue&.close
          producer&.kill&.join
        end
      end
    end

    def test_waiting_and_full_checks_tolerate_concurrent_unbounded_transitions
      public_classes.each do |type|
        queue = type.new(capacity: 1)
        enqueue(queue, :first)
        start = Flag.new
        writer = Thread.new do
          start.wait_until_set
          1000.times do
            queue.capacity = nil
            queue.capacity = 1
          end
        end
        reader = Thread.new do
          start.wait_until_set
          1000.times do
            queue.full?
            queue.wait_push(timeout: 0)
          end
        end
        start.set

        assert writer.join(5)
        assert reader.join(5)
        writer.value
        reader.value

        assert_equal :first, queue.pop
      ensure
        start&.set
        queue&.close
        writer&.kill&.join
        reader&.kill&.join
      end
    end

    def test_local_resize_preserves_other_scopes_constructor_default
      [Local::PriorityQueue, Local::TimerQueue].each do |type|
        queue = type.new(capacity: 2)
        queue.capacity = 3
        caller = Ractor.new(queue) do |target|
          before = target.capacity
          target.capacity = nil
          Ractor.make_shareable([before, target.capacity])
        end

        assert_equal [2, nil], caller.respond_to?(:value) ? caller.value : caller.take
        assert_equal 3, queue.capacity
      end
    end

    def test_resize_from_another_ractor
      [PriorityQueue, Strict::PriorityQueue, TimerQueue, Strict::TimerQueue].each do |type|
        queue = type.new(capacity: 1)
        caller = Ractor.new(queue) do |target|
          target.capacity = nil
          target.capacity
        end

        assert_nil caller.respond_to?(:value) ? caller.value : caller.take
        assert_nil queue.capacity
      end
    end

    def test_resize_wakes_a_waiting_fiber
      return unless Internal.native_ractors?
      public_classes.each do |type|
        [2, nil].each do |limit|
          scheduler = Helpers::QueueTestScheduler.new
          Fiber.set_scheduler(scheduler)
          queue = type.new(capacity: 1)
          enqueue(queue, :first)
          events = []
          Fiber.schedule do
            enqueue(queue, :second)
            events << :pushed
          end
          Fiber.schedule { queue.capacity = limit }
          Fiber.set_scheduler(nil)

          assert_equal [:pushed], events
          assert_equal %i[first second], Array.new(2) { queue.pop }
        ensure
          queue&.close
          Fiber.set_scheduler(nil)
        end
      end
    end

    private

    def storage_classes = [Internal::PriorityQueue, Internal::UnsharedPriorityQueue].uniq

    def public_classes
      [Farce, Strict, Unshared, Local].flat_map { |namespace| [namespace::PriorityQueue, namespace::TimerQueue] }
    end

    def enqueue(queue, value, non_block: false)
      options = queue.is_a?(Abstract::TimerQueue) ? { at: 0 } : { priority: 1 }
      non_block ? queue.try_push(value, **options) : queue.push(value, **options)
    end
  end
end
