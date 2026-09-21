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
        refute_predicate queue, :frozen?
        assert Ractor.shareable?(queue)
        assert_raises(ArgumentError) { Queue.new(capacity: 0) }
        assert_raises(ArgumentError) { Queue.new(capacity: -1) }
      end

      def test_initialization_and_nonblocking_operations_do_not_consume_descriptors
        return unless before = open_file_descriptor_count

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

      def test_gc_preserves_values_in_full_and_partially_filled_wrapped_rings
        return unless GC.respond_to?(:verify_compaction_references)

        [31, nil].each do |capacity|
          [10, 20].each do |added|
            queue = Queue.new(capacity:)
            31.times { |index| queue.push("value #{index}".freeze) }
            20.times { queue.pop }
            added.times { |index| queue.push("value #{index + 31}".freeze) }
            GC.verify_compaction_references(double_heap: true, toward: :empty)

            expected = (20...(31 + added)).map { |index| "value #{index}" }

            assert_equal expected, Array.new(queue.size) { queue.pop }

            queue.push(:after_compaction)

            assert_equal :after_compaction, queue.pop
          end
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

      def test_try_operations_preserve_fallbacks_values_and_errors
        queue = Queue.new(capacity: 1)

        assert_equal(:empty, queue.try_pop { :empty })
        assert queue.try_push(nil)
        refute queue.try_push(:full)
        assert_nil(queue.try_pop { flunk "nil is a stored value" })
        assert queue.try_push(false)
        assert_instance_of FalseClass, queue.try_pop
        assert_raises(Ractor::IsolationError) { queue.try_push(ModePayload.new(:rejected)) }
        assert_equal 0, queue.size
        queue.close

        assert_raises(ClosedQueueError) { queue.try_pop }
        assert_raises(ClosedQueueError) { queue.try_push(:closed) }
      end

      def test_polling_with_a_coerced_capacity
        return if RUBY_ENGINE == "truffleruby"
        capacity = Object.new
        def capacity.to_int = 1
        queue = Queue.new(capacity:)

        assert queue.push(:first, timeout: 0)
        refute queue.push(:full, timeout: 0)
        assert_equal :first, queue.pop(timeout: 0)
        assert queue.try_push(:second)
        refute queue.try_push(:full)
        assert_equal :second, queue.try_pop
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

      def test_keyword_fast_paths_preserve_arguments_and_validate_timeouts
        queue = Queue.new(capacity: 1)
        options = { timeout: 0 }.freeze
        value = { timeout: :payload }.freeze

        assert queue.push(value, **options)
        assert_same value, queue.pop(**options)
        assert_equal({ timeout: 0 }, options)
        assert queue.push(value)
        assert_same value, queue.pop

        %i[pop wait_pop wait_push].each do |method|
          assert_raises(ArgumentError) { queue.public_send(method, unknown: 0) }
          assert_raises(ArgumentError) { queue.public_send(method, timeout: 0, unknown: 0) }
          assert_raises(ArgumentError) { queue.public_send(method, options) }
          assert_raises(ArgumentError) { queue.public_send(method, timeout: Float::NAN) }
        end
        assert_raises(ArgumentError) { queue.push(timeout: 0) }
        assert_raises(ArgumentError) { queue.push(:value, unknown: 0) }
        assert_raises(ArgumentError) { queue.push(:value, timeout: 0, unknown: 0) }
        assert_raises(ArgumentError) { queue.push(:value, options) }
        assert_raises(ArgumentError) { queue.push(:value, :extra, timeout: 0) }
        assert_equal 0, queue.size

        queue.push(:ready)
        assert_raises(ArgumentError) { queue.pop(timeout: -1) }
        assert_raises(ArgumentError) { queue.wait_pop(timeout: Float::INFINITY) }
        assert_equal :ready, queue.pop
      end

      def test_zero_timeouts_preserve_nil_false_and_fallback_values
        queue = Queue.new(capacity: 1)

        [0, 0.0, -0.0, Rational(0)].each do |timeout|
          assert_equal :empty, queue.pop(timeout:) { :empty }
          refute queue.wait_pop(timeout:)
          assert queue.wait_push(timeout:)
          [nil, false].each do |value|
            assert queue.push(value, timeout:)
            refute queue.push(:full, timeout:)
            refute queue.wait_push(timeout:)
            assert queue.wait_pop(timeout:)
            result = queue.pop(timeout:) { flunk "stored values must not call the fallback" }
            value.nil? ? assert_nil(result) : assert_same(value, result)
          end
        end
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

        assert_instance_of Farce::ClosedQueueError, thread.value
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

        assert_instance_of Farce::ClosedQueueError, thread.value
      end

      def test_interrupted_native_waiters_leave_their_siblings_usable
        return unless RUBY_ENGINE == "ruby"

        %i[pop push].each do |operation|
          queue = Queue.new(capacity: 1)
          queue.push(:first) if operation == :push
          waiters = 2.times.map do
            Thread.new { operation == :pop ? queue.pop : queue.push(:replacement) }
          end
          Timeout.timeout(5) { Thread.pass until queue.num_waiting == 2 }
          waiters.first.kill
          Timeout.timeout(5) { waiters.first.join }

          assert_equal 1, queue.num_waiting
          operation == :pop ? queue.push(:value) : queue.pop
          result = Timeout.timeout(5) { waiters.last.value }

          assert_equal(operation == :pop ? :value : true, result)
          assert_equal 0, queue.num_waiting
          queue.close
        ensure
          queue&.close
          waiters&.each(&:kill)
          waiters&.each(&:join)
        end
      end

      def test_close_wakes_all_data_and_readiness_waiters
        %i[pop push].each do |operation|
          queue = Queue.new(capacity: 1)
          queue.push(:first) if operation == :push
          waiters = 8.times.map do |index|
            Thread.new do
              if index.even?
                queue.public_send(:"wait_#{operation}")
              else
                operation == :pop ? queue.pop : queue.push(:replacement)
              end
            rescue ClosedQueueError
              :closed
            end
          end
          Timeout.timeout(5) { Thread.pass until queue.num_waiting == waiters.size }
          queue.close

          assert_equal [:closed] * 8, Timeout.timeout(5) { waiters.map(&:value) }
          assert_equal 0, queue.num_waiting
        ensure
          queue&.close
          waiters&.each(&:kill)
          waiters&.each(&:join)
        end
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
