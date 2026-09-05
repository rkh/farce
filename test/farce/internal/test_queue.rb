# frozen_string_literal: true

require_relative "../../setup"

module Farce
  module Internal
    class TestQueue < Test
      include Helpers::InternalTestHelpers

      def test_initialization
        queue = Queue.new

        assert_equal 1024, queue.capacity
        assert_equal 0, queue.size
        assert_equal 0, queue.num_waiting
        refute_predicate queue, :closed?
        assert_respond_to queue, :pop
        refute_respond_to queue, :pull
        assert_respond_to queue, :wait_pop
        refute_respond_to queue, :wait_pull
        refute Internal.const_defined?(:QueueClosedError, false)
        assert_predicate queue, :frozen?
        assert Ractor.shareable?(queue)
        assert_raises(ArgumentError) { Queue.new(capacity: 0) }
        assert_raises(ArgumentError) { Queue.new(capacity: -1) }
      end

      def test_initialization_and_nonblocking_operations_do_not_consume_descriptors
        before = open_file_descriptor_count
        skip "open descriptor count is not available" unless before

        queues = 1_000.times.map { Queue.new }
        queues.each { |queue| queue.pop(timeout: 0) }

        assert_operator open_file_descriptor_count, :<=, before
      end

      def test_explicit_nil_capacity_creates_an_unbounded_queue
        queue = Queue.new(capacity: nil)
        values = 10_000.times.to_a

        assert_nil queue.capacity
        assert queue.wait_push(timeout: 0)
        assert(values.all? { |value| queue.push(value, timeout: 0) })
        assert_equal values.size, queue.size
        assert_equal(values, values.map { queue.pop(timeout: 0) })
        assert_equal 0, queue.size
      end

      def test_unbounded_queue_grows_after_the_ring_has_wrapped
        queue = Queue.new(capacity: nil)
        32.times { |value| queue.push(value) }

        20.times { |value| assert_equal value, queue.pop }

        32.upto(52) { |value| queue.push(value) }

        assert_equal((20..52).to_a, 33.times.map { queue.pop })
      end

      def test_capacity_one_ring_buffer_wraps_around
        queue = Queue.new(capacity: 1)

        100.times do |value|
          assert queue.push(value, timeout: 0)
          assert_equal value, queue.pop(timeout: 0)
        end
      end

      def test_fifo_and_size
        queue = Queue.new(capacity: 2)

        assert queue.push(:first)
        assert queue.push(:second)
        assert_equal 2, queue.size
        assert_equal :first, queue.pop
        assert_equal :second, queue.pop
        assert_equal 0, queue.size
      end

      def test_clear_empties_the_queue_and_returns_self
        queue = Queue.new(capacity: 3)
        queue.push(:first)
        queue.push(:second)

        assert_same queue, queue.clear
        assert_equal 0, queue.size
        assert_nil queue.pop(timeout: 0)
        assert_equal 3, queue.capacity
        assert queue.push(:after_clear)
        assert_equal :after_clear, queue.pop
      end

      def test_clear_empties_a_grown_and_wrapped_unbounded_queue
        queue = Queue.new(capacity: nil)
        32.times { |value| queue.push(value) }
        20.times { queue.pop }
        32.upto(52) { |value| queue.push(value) }

        assert_same queue, queue.clear
        assert_equal 0, queue.size
        assert_nil queue.capacity
        assert_nil queue.pop(timeout: 0)
        assert queue.push(:after_clear)
        assert_equal :after_clear, queue.pop
      end

      def test_clear_wakes_a_blocked_push
        queue = Queue.new(capacity: 1)
        queue.push(:discarded)
        producer = Thread.new { queue.push(:replacement) }
        sleep 0.01

        queue.clear

        assert producer.value
        assert_equal :replacement, queue.pop
      end

      def test_rejects_unshareable_values
        return unless Internal.native_ractors?
        queue = Queue.new

        assert_raises(Ractor::IsolationError) { queue.push(Object.new) }
      end

      def test_rejects_explicitly_unshareable_values
        queue = Queue.new

        assert_raises(Ractor::IsolationError) { queue.push(ModePayload.new(:rejected)) }
        assert_equal 0, queue.size
      end

      def test_zero_timeout
        queue = Queue.new(capacity: 1)

        assert_nil queue.pop(timeout: 0)
        assert queue.push(1, timeout: 0)
        refute queue.push(2, timeout: 0)
        assert_equal 1, queue.pop(timeout: 0)
      end

      def test_pop_timeout_and_fallback_block
        queue = Queue.new
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        assert_equal :fallback, queue.pop(timeout: 0.02) { :fallback }
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        assert_operator elapsed, :>=, 0.01
      end

      def test_invalid_timeouts
        queue = Queue.new

        assert_raises(ArgumentError) { queue.pop(timeout: -1) }
        assert_raises(ArgumentError) { queue.push(1, timeout: Float::INFINITY) }
      end

      def test_blocking_pop
        queue = Queue.new
        consumer = Thread.new { queue.pop }
        sleep 0.01

        queue.push(:value)

        assert_equal :value, consumer.value
      end

      def test_blocking_push
        queue = Queue.new(capacity: 1)
        queue.push(:first)
        producer = Thread.new { queue.push(:second) }
        sleep 0.01

        assert_equal :first, queue.pop
        assert producer.value
        assert_equal :second, queue.pop
      end

      def test_wait_pop_and_wait_push
        queue = Queue.new(capacity: 1)

        refute queue.wait_pop(timeout: 0)
        assert queue.wait_push(timeout: 0)
        queue.push(1)

        assert queue.wait_pop(timeout: 0)
        refute queue.wait_push(timeout: 0)
        assert_equal 1, queue.size
      end

      def test_num_waiting_tracks_pop_and_push_waiters
        queue = Queue.new(capacity: 1)
        consumer = Thread.new { queue.pop }

        Timeout.timeout(5) { Thread.pass until queue.num_waiting.positive? }

        assert_operator queue.num_waiting, :>=, 1
        queue.push(:first)

        assert_equal :first, consumer.value

        queue.push(:second)
        producer = Thread.new { queue.push(:replacement) }

        Timeout.timeout(5) { Thread.pass until queue.num_waiting.positive? }

        assert_operator queue.num_waiting, :>=, 1
        assert_equal :second, queue.pop
        assert producer.value
        assert_equal :replacement, queue.pop
        assert_equal 0, queue.num_waiting
      ensure
        consumer&.kill if consumer&.alive?
        producer&.kill if producer&.alive?
      end

      def test_close_is_idempotent_and_data_operations_raise
        queue = Queue.new
        queue.push(1)

        assert_same queue, queue.close
        assert_same queue, queue.close
        assert_predicate queue, :closed?
        assert_same queue, queue.clear
        assert_equal 0, queue.size
        assert_raises(::ClosedQueueError) { queue.pop }
        assert_raises(::ClosedQueueError) { queue.push(2) }
        assert_raises(::ClosedQueueError) { queue.wait_pop }
        assert_raises(::ClosedQueueError) { queue.wait_push }
      end

      def test_close_wakes_blocked_pop
        queue = Queue.new
        thread = Thread.new do
          queue.pop
        rescue StandardError => e
          e
        end
        sleep 0.01

        queue.close

        assert_instance_of ::ClosedQueueError, thread.value
      end

      def test_close_wakes_blocked_push
        queue = Queue.new(capacity: 1)
        queue.push(1)
        thread = Thread.new do
          queue.push(2)
        rescue StandardError => e
          e
        end
        sleep 0.01

        queue.close

        assert_instance_of ::ClosedQueueError, thread.value
      end

      def test_multiple_producers_and_consumers
        queue = Queue.new(capacity: 32)
        values = 4.times.flat_map { |producer| 250.times.map { |index| (producer * 1_000) + index } }
        producers = values.each_slice(250).map do |slice|
          Thread.new { slice.each { |value| queue.push(value) } }
        end
        consumers = 4.times.map do
          Thread.new { 250.times.map { queue.pop } }
        end

        producers.each(&:join)
        received = consumers.flat_map(&:value)

        assert_equal values.sort, received.sort
      end
    end
  end
end
