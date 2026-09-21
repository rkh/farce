# frozen_string_literal: true

require_relative "../setup"

module Farce
  class TestPriorityQueue < Test
    class HostileIdentityValue
      def initialize(identity_answer)
        @identity_answer = identity_answer
      end

      def equal?(_other) = @identity_answer
    end

    include Helpers::InternalTestHelpers

    def test_initialization_and_hierarchy
      queue = PriorityQueue.new

      assert_equal Abstract::PriorityQueue, PriorityQueue.superclass
      assert_instance_of Internal::PriorityQueue, queue.instance_variable_get(:@queue)
      assert_nil queue.capacity
      assert_equal Float::INFINITY, queue.max
      assert_equal 0, queue.default_priority
      assert_equal :ascending, queue.order
      assert_equal :copy, queue.mode
      assert_equal 0, queue.size
      assert_predicate queue, :empty?
      refute_predicate queue, :closed?
      refute_predicate queue, :frozen?
      assert Ractor.shareable?(queue) if RUBY_ENGINE == "ruby"
      assert_raises(ArgumentError) { PriorityQueue.new(capacity: 0) }
      assert_raises(ArgumentError) { PriorityQueue.new(capacity: -1) }
      error = assert_raises(ArgumentError) { PriorityQueue.new(order: :sideways) }
      assert_equal "order must be :ascending or :descending", error.message
      assert_raises(TypeError) { queue.dup }
      assert_raises(ArgumentError) { PriorityQueue.new(mode: :invalid) }
      refute_respond_to queue, :delete_identity
    end

    def test_modes_wrap_only_values_and_reads_automatically_unwrap_them
      queue = PriorityQueue.new(mode: :local)
      local = ModePayload.new(:local)

      assert queue.push(local, priority: 2)
      assert_same local, queue.peek
      assert_same local, queue.pop

      source = ModePayload.new(:original)

      assert queue.try_push(source, priority: 1, mode: :copy)
      source.value = :changed

      copy = queue.try_pop

      refute_same source, copy
      assert_equal :original, copy.value

      assert_raises(Ractor::IsolationError) do
        queue.try_push(ModePayload.new(:rejected), priority: 1, mode: :raise)
      end
      assert_equal :local, queue.mode
    end

    def test_nonblocking_interface_and_fallbacks
      queue = PriorityQueue.new(capacity: 1)

      assert_equal(:empty, queue.try_pop { :empty })
      assert queue.try_push(nil, priority: 2)
      assert_predicate queue, :full?
      assert_equal :full, queue.try_push(:blocked, priority: 1) { :full }
      assert_nil queue.try_pop
      assert_predicate queue, :empty?
    end

    def test_queue_compatible_non_block_argument
      queue = PriorityQueue.new(capacity: 2, order: :descending)

      assert_equal 2, queue.capacity
      assert_equal 2, queue.max

      assert queue.push(:low, true, priority: 1)
      assert queue.enq(:high, true, priority: 2)

      error = assert_raises(ThreadError) { queue.push(:blocked, true, priority: 3) }

      assert_equal "queue full", error.message
      assert_equal :high, queue.pop(true)
      assert_equal :low, queue.deq(true)

      error = assert_raises(ThreadError) do
        queue.pop(true) { flunk "a non-blocking pop must not use the timeout fallback" }
      end

      assert_equal "queue empty", error.message
      assert_predicate queue, :empty?
    end

    def test_default_priority
      queue = PriorityQueue.new(default_priority: 7)

      assert_equal 7, queue.default_priority
      assert queue.push(:first)
      assert queue.try_push(:second)
      assert_equal 7, queue.first_priority
      assert_equal 7, queue.last_priority
      assert_equal :first, queue.pop
      assert_equal :second, queue.pop
    end

    def test_abstract_queue_aliases
      queue = PriorityQueue.new(capacity: 2)

      assert_equal 2, queue.max
      assert queue.enq(:second, priority: 2)
      assert queue.public_send(:<<, :first, priority: 1)
      assert_equal 2, queue.length
      assert_predicate queue, :full?
      assert_equal :first, queue.deq
      assert_equal :second, queue.shift
    end

    def test_minimum_order_and_fifo_ties
      queue = PriorityQueue.new
      first = Object.new.freeze
      second = Object.new.freeze

      queue.push(:later, priority: 3)
      queue.push(first, priority: 1)
      queue.push(second, priority: 1)
      queue.push(:middle, priority: 2)

      assert_equal 1, queue.first_priority
      assert_equal 3, queue.last_priority
      assert_same first, queue.peek
      assert_same first, queue.pop
      assert_same second, queue.pop
      assert_equal :middle, queue.pop
      assert_equal :later, queue.pop
      assert_predicate queue, :empty?
    end

    def test_descending_order_uses_maximum_priority_and_preserves_fifo_ties
      queue = PriorityQueue.new(order: :descending)
      first = Object.new.freeze
      second = Object.new.freeze

      queue.push(:earliest, priority: 1)
      queue.push(first, priority: 3)
      queue.push(second, priority: 3)
      queue.push(:middle, priority: 2)

      assert_equal :descending, queue.order
      assert_equal 3, queue.first_priority
      assert_equal 1, queue.last_priority
      assert_same first, queue.peek
      assert_same first, queue.try_pop
      assert_same second, queue.pop
      assert_equal :middle, queue.pop
      assert_equal :earliest, queue.pop
      assert_predicate queue, :empty?
    end

    def test_unbounded_capacity
      queue = PriorityQueue.new(capacity: nil)

      assert_nil queue.capacity
      assert queue.wait_push(timeout: 0)
      10_000.times { assert queue.push(it, priority: it % 7, timeout: 0) }

      assert_equal 10_000, queue.size
    end

    def test_exact_pair_deletion
      queue = PriorityQueue.new
      equal_class = Data.define(:group, :tag) do
        def ==(other) = other.is_a?(self.class) && group == other.group
      end
      first = equal_class.new(:same, :first).freeze
      second = equal_class.new(:same, :second).freeze
      third = equal_class.new(:same, :third).freeze

      queue.push(first, priority: 1)
      queue.push(second, priority: 1)
      queue.push(third, priority: 1)
      queue.push(first, priority: 2)

      assert queue.delete(second, priority: 1)
      assert_same second, queue.pop
      assert_same third, queue.pop
      assert_same first, queue.pop
      refute queue.delete(second, priority: 1)
    end

    def test_delete_compares_copied_values_without_exposing_envelopes
      queue = PriorityQueue.new
      source = ModePayload.new(:same)

      queue.push(source, priority: 1)

      assert queue.delete(ModePayload.new(:same), priority: 1)
      assert_predicate queue, :empty?
    end

    def test_delete_compares_moved_values_without_claiming_nonmatches
      queue = PriorityQueue.new(mode: :move)
      queue.push(ModePayload.new(:stored), priority: 1)
      envelope = queue.instance_variable_get(:@queue).peek

      refute queue.delete(ModePayload.new(:other), priority: 1)
      refute_predicate envelope, :claimed?
      assert queue.delete(ModePayload.new(:stored), priority: 1)
      refute_predicate envelope, :claimed?
    end

    def test_identity_delete_can_match_the_value_returned_by_peek
      queue = PriorityQueue.new
      queue.push(ModePayload.new(:stored), priority: 1)
      value = queue.peek

      assert queue.delete(value, priority: 1, compare_by_identity: true)
      assert_predicate queue, :empty?
    end

    def test_identity_deletion_does_not_remove_an_equal_distinct_value
      queue = PriorityQueue.new
      value_class = Data.define(:group, :tag) do
        def ==(other) = other.is_a?(self.class) && group == other.group
      end
      first = value_class.new(:same, :first).freeze
      target = value_class.new(:same, :target).freeze

      queue.push(first, priority: 1)
      queue.push(target, priority: 1)

      assert queue.delete(target, priority: 1, compare_by_identity: true)
      assert_same first, queue.pop
      refute queue.delete(target, priority: 1, compare_by_identity: true)
    end

    def test_identity_deletion_bypasses_an_overridden_equal
      primitive_equal = BasicObject.instance_method(:equal?)
      impostor = HostileIdentityValue.new(true).freeze
      target = Object.new.freeze
      queue = PriorityQueue.new(capacity: nil)
      queue.push(impostor, priority: 1)
      queue.push(target, priority: 1)

      assert queue.delete(target, priority: 1, compare_by_identity: true)
      assert primitive_equal.bind_call(impostor, queue.pop)

      self_denial = HostileIdentityValue.new(false).freeze
      40.times { queue.push(Object.new.freeze, priority: 1) }
      queue.push(self_denial, priority: 1)

      assert queue.delete(self_denial, priority: 1, compare_by_identity: true)
      assert_equal 40, queue.size
    end

    def test_nil_payload
      queue = PriorityQueue.new

      queue.push(nil, priority: 1)

      assert_nil queue.peek
      assert_equal 1, queue.size
      assert_nil queue.pop
      assert_predicate queue, :empty?
    end

    def test_public_undefined_sentinel_is_a_valid_payload
      queue = PriorityQueue.new

      queue.push(UNDEFINED, priority: 1)

      assert_same UNDEFINED, queue.pop(timeout: 0)
      assert_predicate queue, :empty?
    end

    def test_zero_and_finite_timeouts
      queue = PriorityQueue.new(capacity: 1)

      assert_nil queue.pop(timeout: 0)
      assert queue.push(:first, priority: 1, timeout: 0)
      refute queue.push(:second, priority: 2, timeout: 0)
      queue.clear

      assert_equal :fallback, queue.pop(timeout: 0.02) { :fallback }
      assert_raises(ArgumentError) { queue.pop(timeout: -1) }
      assert_raises(ArgumentError) { queue.push(:value, priority: 1, timeout: Float::INFINITY) }
    end

    def test_blocking_pop_and_push
      queue = PriorityQueue.new(capacity: 1)
      consumer = Thread.new { queue.pop }
      sleep 0.01
      queue.push(:first, priority: 2)

      assert_equal :first, consumer.value

      queue.push(:second, priority: 2)
      producer = Thread.new { queue.push(:replacement, priority: 1) }
      sleep 0.01

      assert_equal :second, queue.pop
      assert producer.value
      assert_equal :replacement, queue.pop
    end

    def test_wait_methods
      queue = PriorityQueue.new(capacity: 1)

      refute queue.wait_pop(timeout: 0)
      assert queue.wait_push(timeout: 0)
      queue.push(:value, priority: 1)

      assert queue.wait_pop(timeout: 0)
      refute queue.wait_push(timeout: 0)
    end

    def test_scheduled_producer_and_consumer_repeatedly_handoff_capacity
      return unless Fiber.respond_to?(:set_scheduler)
      scheduler = Helpers::QueueTestScheduler.new
      queue = PriorityQueue.new(capacity: 1)
      received = []
      begin
        Fiber.set_scheduler(scheduler)
        Fiber.schedule { 300.times { received << queue.pop } }
        Fiber.schedule { 300.times { queue.push(it, priority: 1.0) } }

        Timeout.timeout(5) { Fiber.set_scheduler(nil) }

        assert_equal (0...300).to_a, received
        assert_equal 0, queue.num_waiting
        assert_predicate queue, :empty?
        assert_operator scheduler.io_wait_calls, :>=, 1
      ensure
        queue.close
        Fiber.set_scheduler(nil)
      end
    end

    def test_num_waiting_tracks_blocked_pop_and_push
      queue = PriorityQueue.new(capacity: 1)
      consumer = Thread.new { queue.pop }

      Timeout.timeout(5) { Thread.pass until queue.num_waiting.positive? }

      assert_operator queue.num_waiting, :>=, 1

      queue.push(:first, priority: 2)

      assert_equal :first, consumer.value

      queue.push(:second, priority: 2)
      producer = Thread.new { queue.push(:replacement, priority: 1) }

      Timeout.timeout(5) { Thread.pass until queue.num_waiting.positive? }

      assert_operator queue.num_waiting, :>=, 1
      assert_equal :second, queue.pop
      assert producer.value
      assert_equal :replacement, queue.pop
    ensure
      consumer&.kill if consumer&.alive?
      producer&.kill if producer&.alive?
    end

    def test_clear_and_close_wake_waiters
      queue = PriorityQueue.new(capacity: 1)
      queue.push(:discarded, priority: 1)
      producer = Thread.new { queue.push(:replacement, priority: 2) }
      sleep 0.01

      assert_same queue, queue.clear
      assert producer.value
      assert_equal :replacement, queue.pop

      consumer = Thread.new do
        queue.pop
      rescue StandardError => e
        e
      end
      sleep 0.01

      assert_same queue, queue.close
      assert_instance_of ClosedQueueError, consumer.value
      assert_same queue, queue.close
      assert_predicate queue, :closed?
      assert_raises(ClosedQueueError) { queue.push(:value, priority: 1) }
      assert_raises(ClosedQueueError) { queue.pop }
    end

    def test_wait_pop_raises_on_a_closed_queue_even_when_values_remain
      queue = PriorityQueue.new
      queue.push(:discarded, priority: 1)
      queue.close

      assert_raises(ClosedQueueError) { queue.wait_pop(timeout: 0) }
    end

    def test_async_interruption_after_native_commit_does_not_strand_a_waiter
      return unless RUBY_ENGINE == "ruby"

      queue = PriorityQueue.new
      consumer = Thread.new { queue.pop }
      Timeout.timeout(1) { Thread.pass until consumer.status == "sleep" }
      cancellation = Class.new(StandardError)
      native_class = Internal::PriorityQueue
      producer = nil
      trace = TracePoint.new(:c_return) do |event|
        next unless Thread.current == producer
        next unless event.method_id == :push && event.defined_class == native_class

        raise cancellation, "cancel immediately after the native commit"
      end
      producer = Thread.new do
        trace.enable { queue.push(:stored, priority: 1) }
      rescue cancellation => e
        e
      end

      assert_instance_of cancellation, producer.value
      assert consumer.join(1), "consumer remained asleep after the committed push"
      assert_equal :stored, consumer.value
    ensure
      trace&.disable
      producer&.kill if producer&.alive?
      consumer&.kill if consumer&.alive?
    end

    def test_rejects_unshareable_priorities_on_cruby
      return unless RUBY_ENGINE == "ruby"
      queue = PriorityQueue.new

      assert_raises(Ractor::IsolationError) { queue.push(:value, priority: Object.new) }
    end

    def test_cross_ractor_producers_and_consumer
      return unless RUBY_ENGINE == "ruby"
      queue = PriorityQueue.new(capacity: nil)
      producers = 4.times.map do |worker|
        Ractor.new(queue, worker) do |shared, prefix|
          250.times { |index| shared.push((prefix * 1_000) + index, priority: index % 8) }
        end
      end
      producers.each { ractor_value(it) }

      values = Ractor.new(queue) { |shared| 1_000.times.map { shared.pop } }
      actual = ractor_value(values)
      expected = 4.times.flat_map { |worker| 250.times.map { |index| (worker * 1_000) + index } }

      assert_equal expected.sort, actual.sort
    end

    def test_copies_unshareable_values_across_cruby_ractors
      return unless RUBY_ENGINE == "ruby"
      queue = PriorityQueue.new
      queue.push(ModePayload.new(:value), priority: 1)

      result = Ractor.new(queue) { |shared| shared.pop.value }

      assert_equal :value, ractor_value(result)
    end
  end
end
