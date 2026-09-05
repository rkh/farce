# frozen_string_literal: true

require_relative "../setup"
require "pp"

module Farce
  class TestStrictQueue < Test
    include Helpers::InternalTestHelpers

    def test_initialization_hierarchy_and_interface
      queue = StrictQueue.new

      assert_equal Abstract::Queue, StrictQueue.superclass
      assert_equal 1024, queue.capacity
      assert_equal 1024, queue.max
      assert_equal 0, queue.size
      assert_equal 0, queue.length
      assert_equal 0, queue.num_waiting
      assert_equal :raise, queue.mode
      assert_predicate queue, :empty?
      refute_predicate queue, :full?
      refute_predicate queue, :closed?
      assert_predicate queue, :frozen?
      assert Ractor.shareable?(queue)
      assert_raises(ArgumentError) { StrictQueue.new(capacity: 0) }
      assert_raises(ArgumentError) { StrictQueue.new(capacity: -1) }
      assert_raises(TypeError) { queue.dup }
      assert_raises(TypeError) { queue.clone }
    end

    def test_transfer_mode_cannot_be_overridden
      queue = StrictQueue.new

      assert_raises(ArgumentError) { StrictQueue.new(mode: :copy) }
      assert_raises(ArgumentError) { queue.push(:value, mode: :copy) }
      assert_raises(ArgumentError) { queue.try_push(:value, mode: :make_shareable) }
      assert_predicate queue, :empty?
    end

    def test_shareable_values_preserve_identity_and_fifo_order
      queue = StrictQueue.new
      values = [false, true, 42, :value, "frozen", [:nested, "value"].freeze, StrictQueue.new]

      values.each { |value| assert queue.push(value) }

      assert_equal values.size, queue.length
      values.each { |value| assert_same value, queue.pop }
      assert_predicate queue, :empty?
    end

    def test_envelopes_are_returned_without_unwrapping
      queue = StrictQueue.new
      envelope = Envelope.new(ModePayload.new(:value), mode: :local)

      assert queue.push(envelope)
      assert_same envelope, queue.pop
      assert queue.try_push(envelope)
      assert_same envelope, queue.try_pop
    end

    def test_push_methods_reject_unshareable_values_without_changing_them
      queue = StrictQueue.new
      value = ModePayload.new(:original)

      %i[push try_push enq <<].each do |method|
        assert_raises(Ractor::IsolationError) { queue.public_send(method, value) }
        assert_predicate queue, :empty?
        assert_equal :original, value.value
      end

      value.value = :changed

      assert_equal :changed, value.value
    end

    def test_rejects_mutable_and_shallow_frozen_values_on_cruby
      return unless Internal.native_ractors?
      queue = StrictQueue.new
      mutable = +"mutable"
      shallow = [mutable].freeze

      [Object.new, mutable, shallow].each do |value|
        assert_raises(Ractor::IsolationError) { queue.push(value) }
        assert_raises(Ractor::IsolationError) { queue.try_push(value) }
      end

      refute_predicate mutable, :frozen?
      assert_predicate queue, :empty?
    end

    def test_full_queue_still_rejects_unshareable_values
      queue = StrictQueue.new(capacity: 1)
      queue.push(:first)
      value = ModePayload.new(:rejected)

      assert_raises(Ractor::IsolationError) { queue.push(value, true) }
      assert_raises(Ractor::IsolationError) { queue.push(value, timeout: 0) }
      assert_raises(Ractor::IsolationError) do
        queue.try_push(value) { flunk "unshareable values must not use the full queue fallback" }
      end
      assert_equal 1, queue.size
      assert_equal :first, queue.pop
    end

    def test_aliases_and_non_block_argument
      queue = StrictQueue.new(capacity: 2)

      assert queue.enq(nil, true)
      assert queue.public_send(:<<, false)
      assert_predicate queue, :full?

      error = assert_raises(ThreadError) { queue.push(:blocked, true) }

      assert_equal "queue full", error.message
      assert_nil queue.deq(true)
      assert_same false, queue.shift(true)

      error = assert_raises(ThreadError) do
        queue.pop(true) { flunk "a non-blocking pop must not use the timeout fallback" }
      end

      assert_equal "queue empty", error.message
    end

    def test_try_operations_and_fallbacks
      queue = StrictQueue.new(capacity: 1)
      fallback = Object.new

      assert_nil queue.try_pop
      assert_same(fallback, queue.try_pop { fallback })
      assert queue.try_push(nil) { flunk "a successful push must not call the fallback" }
      refute queue.try_push(:blocked)
      assert_same fallback, queue.try_push(:blocked) { fallback }
      assert_nil(queue.try_pop { flunk "a stored nil must not call the fallback" })
      assert queue.try_push(false)
      assert_same(false, queue.try_pop { flunk "a stored false must not call the fallback" })
      assert_predicate queue, :empty?
    end

    def test_timeouts_and_fallbacks
      queue = StrictQueue.new(capacity: 1)
      fallback = Object.new

      assert_nil queue.pop(timeout: 0)
      assert_same fallback, queue.pop(timeout: 0) { fallback }
      assert queue.push(nil, timeout: 0)
      refute queue.push(:blocked, timeout: 0)
      assert_nil(queue.pop(timeout: 0) { flunk "a stored nil must not call the fallback" })
      assert_raises(ArgumentError) { queue.pop(timeout: -1) }
      assert_raises(ArgumentError) { queue.push(:value, timeout: Float::INFINITY) }
    end

    def test_unbounded_capacity
      queue = StrictQueue.new(capacity: nil)
      values = 2_000.times.to_a

      assert_nil queue.capacity
      assert_equal Float::INFINITY, queue.max
      refute_predicate queue, :full?
      assert queue.wait_push(timeout: 0)
      assert(values.all? { |value| queue.try_push(value) })
      assert_equal values.size, queue.size
      assert_equal(values, values.map { queue.try_pop })
    end

    def test_blocking_operations_and_wait_methods
      queue = StrictQueue.new(capacity: 1)

      refute queue.wait_pop(timeout: 0)
      assert queue.wait_push(timeout: 0)

      consumer = Thread.new { queue.pop }
      Timeout.timeout(5) { Thread.pass until queue.num_waiting.positive? }
      queue.push(:first)

      assert_equal :first, consumer.value

      queue.push(:second)

      assert queue.wait_pop(timeout: 0)
      refute queue.wait_push(timeout: 0)
      assert_equal 1, queue.size

      producer = Thread.new { queue.push(:replacement) }
      Timeout.timeout(5) { Thread.pass until queue.num_waiting.positive? }

      assert_equal :second, queue.pop
      assert producer.value
      assert_equal :replacement, queue.pop
      assert_equal 0, queue.num_waiting
    ensure
      consumer&.kill if consumer&.alive?
      producer&.kill if producer&.alive?
    end

    def test_clear_wakes_waiting_producers
      queue = StrictQueue.new(capacity: 1)
      queue.push(:discarded)
      producer = Thread.new { queue.push(:replacement) }
      Timeout.timeout(5) { Thread.pass until queue.num_waiting.positive? }

      assert_same queue, queue.clear
      assert producer.value
      assert_equal :replacement, queue.pop
      assert_predicate queue, :empty?
    ensure
      producer&.kill if producer&.alive?
    end

    def test_close_is_idempotent_and_data_operations_raise
      queue = StrictQueue.new

      assert_same queue, queue.close
      assert_same queue, queue.close
      assert_predicate queue, :closed?
      assert_same queue, queue.clear
      assert_raises(ClosedQueueError) { queue.push(:value) }
      assert_raises(ClosedQueueError) { queue.try_push(:value) }
      assert_raises(ClosedQueueError) { queue.pop }
      assert_raises(ClosedQueueError) { queue.try_pop }
      assert_raises(ClosedQueueError) { queue.wait_push }
      assert_raises(ClosedQueueError) { queue.wait_pop }
    end

    def test_inspect_and_pretty_inspect
      queue = StrictQueue.new(capacity: 2)
      queue.push(:value)

      assert_equal "#<Farce::StrictQueue size=1 capacity=2>", queue.inspect
      assert_equal "#<Farce::StrictQueue size=1 capacity=2>\n", queue.pretty_inspect
      assert_equal "#<Farce::StrictQueue size=0>", StrictQueue.new(capacity: nil).inspect

      queue.close

      assert_equal "#<Farce::StrictQueue closed>", queue.inspect
      assert_equal "#<Farce::StrictQueue closed>\n", queue.pretty_inspect
    end

    def test_preserves_identity_across_cruby_ractors
      return unless Internal.native_ractors?
      queue = StrictQueue.new
      value = [:shared].freeze
      queue.push(value)

      result = Ractor.new(queue) do |shared|
        shared.push(shared.pop)
      end

      assert ractor_value(result)
      assert_same value, queue.pop
    end
  end
end
