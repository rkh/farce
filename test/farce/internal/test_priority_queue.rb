# frozen_string_literal: true

return if RUBY_ENGINE == "jruby"
return if RUBY_ENGINE == "truffleruby" && !TruffleRuby.native?

require_relative "../../setup"

module Farce
  class HostileIdentityValue
    def initialize(identity_answer)
      @identity_answer = identity_answer
    end

    def equal?(_other) = @identity_answer
  end

  class TestPriorityQueue < Test
    include Helpers::InternalTestHelpers

    PriorityQueue = Internal::PriorityQueue

    def test_initialization
      queue = PriorityQueue.new

      assert_equal 1024, queue.capacity
      assert_equal 0, queue.size
      assert_predicate queue, :empty?
      refute_predicate queue, :closed?
      assert_predicate queue, :frozen?
      assert Ractor.shareable?(queue) if RUBY_ENGINE == "ruby"
      assert_raises(ArgumentError) { PriorityQueue.new(capacity: 0) }
      assert_raises(ArgumentError) { PriorityQueue.new(capacity: -1) }
    end

    def test_minimum_order_and_fifo_ties
      queue = PriorityQueue.new
      first = Object.new.freeze
      second = Object.new.freeze

      queue.push(3, :later)
      queue.push(1, first)
      queue.push(1, second)
      queue.push(2, :middle)

      assert_equal 1, queue.peek_priority
      assert_same first, queue.peek
      assert_same first, queue.pop
      assert_same second, queue.pop
      assert_equal :middle, queue.pop
      assert_equal :later, queue.pop
      assert_predicate queue, :empty?
    end

    def test_unbounded_capacity
      queue = PriorityQueue.new(capacity: nil)

      assert_nil queue.capacity
      assert queue.wait_push(timeout: 0)
      10_000.times { assert queue.push(it % 7, it, timeout: 0) }

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

      queue.push(1, first)
      queue.push(1, second)
      queue.push(1, third)
      queue.push(2, first)

      assert queue.delete(1, second)
      assert_same second, queue.pop
      assert_same third, queue.pop
      assert_same first, queue.pop
      refute queue.delete(1, second)
    end

    def test_identity_deletion_does_not_remove_an_equal_distinct_value
      queue = PriorityQueue.new
      value_class = Data.define(:group, :tag) do
        def ==(other) = other.is_a?(self.class) && group == other.group
      end
      first = value_class.new(:same, :first).freeze
      target = value_class.new(:same, :target).freeze

      queue.push(1, first)
      queue.push(1, target)

      assert queue.delete_identity(1, target)
      assert_same first, queue.pop
      refute queue.delete_identity(1, target)
    end

    def test_identity_deletion_bypasses_an_overridden_equal
      primitive_equal = BasicObject.instance_method(:equal?)
      impostor = HostileIdentityValue.new(true).freeze
      target = Object.new.freeze
      queue = PriorityQueue.new(capacity: nil)
      queue.push(1, impostor)
      queue.push(1, target)

      assert queue.delete_identity(1, target)
      assert primitive_equal.bind_call(impostor, queue.pop)

      self_denial = HostileIdentityValue.new(false).freeze
      40.times { queue.push(1, Object.new.freeze) }
      queue.push(1, self_denial)

      assert queue.delete_identity(1, self_denial)
      assert_equal 40, queue.size
    end

    def test_nil_payload
      queue = PriorityQueue.new

      queue.push(1, nil)

      assert_nil queue.peek
      assert_equal 1, queue.size
      assert_nil queue.pop
      assert_predicate queue, :empty?
    end

    def test_public_undefined_sentinel_is_a_valid_payload
      queue = PriorityQueue.new

      queue.push(1, UNDEFINED)

      assert_same UNDEFINED, queue.pop(timeout: 0)
      assert_predicate queue, :empty?
    end

    def test_zero_and_finite_timeouts
      queue = PriorityQueue.new(capacity: 1)

      assert_nil queue.pop(timeout: 0)
      assert queue.push(1, :first, timeout: 0)
      refute queue.push(2, :second, timeout: 0)
      queue.clear

      assert_equal :fallback, queue.pop(timeout: 0.02) { :fallback }
      assert_raises(ArgumentError) { queue.pop(timeout: -1) }
      assert_raises(ArgumentError) { queue.push(1, :value, timeout: Float::INFINITY) }
    end

    def test_blocking_pop_and_push
      queue = PriorityQueue.new(capacity: 1)
      consumer = Thread.new { queue.pop }
      sleep 0.01
      queue.push(2, :first)

      assert_equal :first, consumer.value

      queue.push(2, :second)
      producer = Thread.new { queue.push(1, :replacement) }
      sleep 0.01

      assert_equal :second, queue.pop
      assert producer.value
      assert_equal :replacement, queue.pop
    end

    def test_wait_methods
      queue = PriorityQueue.new(capacity: 1)

      refute queue.wait_pop(timeout: 0)
      assert queue.wait_push(timeout: 0)
      queue.push(1, :value)

      assert queue.wait_pop(timeout: 0)
      refute queue.wait_push(timeout: 0)
    end

    def test_clear_and_close_wake_waiters
      queue = PriorityQueue.new(capacity: 1)
      queue.push(1, :discarded)
      producer = Thread.new { queue.push(2, :replacement) }
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
      assert_raises(ClosedQueueError) { queue.push(1, :value) }
      assert_raises(ClosedQueueError) { queue.pop }
    end

    def test_wait_pop_raises_on_a_closed_queue_even_when_values_remain
      queue = PriorityQueue.new
      queue.push(1, :discarded)
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
        next unless event.method_id == :try_push && event.defined_class == native_class

        raise cancellation, "cancel immediately after the native commit"
      end
      producer = Thread.new do
        trace.enable { queue.push(1, :stored) }
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

    def test_cruby_defines_the_native_queue_directly_without_backend_constants
      return unless RUBY_ENGINE == "ruby"

      assert_equal Object, PriorityQueue.superclass
      assert_nil PriorityQueue.instance_method(:try_push).source_location
      assert_nil PriorityQueue.instance_method(:try_pop).source_location
      refute PriorityQueue.public_method_defined?(:try_push)
      refute PriorityQueue.public_method_defined?(:try_pop)
    end

    def test_rejects_unshareable_inputs_on_cruby
      return unless RUBY_ENGINE == "ruby"
      queue = PriorityQueue.new

      assert_raises(Ractor::IsolationError) { queue.push(Object.new, :value) }
      assert_raises(Ractor::IsolationError) { queue.push(1, Object.new) }
    end

    def test_cross_ractor_producers_and_consumer
      return unless RUBY_ENGINE == "ruby"
      queue = PriorityQueue.new(capacity: nil)
      producers = 4.times.map do |worker|
        Ractor.new(queue, worker) do |shared, prefix|
          250.times { |index| shared.push(index % 8, (prefix * 1_000) + index) }
        end
      end
      producers.each { ractor_value(it) }

      values = Ractor.new(queue) { |shared| 1_000.times.map { shared.pop } }
      actual = ractor_value(values)
      expected = 4.times.flat_map { |worker| 250.times.map { |index| (worker * 1_000) + index } }

      assert_equal expected.sort, actual.sort
    end
  end
end
