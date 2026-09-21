# frozen_string_literal: true

require_relative "../setup"
require "pp"

module Farce
  class TestQueue < Test
    include Helpers::InternalTestHelpers

    def test_initialization_hierarchy_and_interface
      queue = Queue.new

      assert_equal Abstract::Queue, Queue.superclass
      assert_instance_of Internal::Queue, queue.instance_variable_get(:@queue)
      assert_equal 1024, queue.capacity
      assert_equal 1024, queue.max
      assert_equal 0, queue.size
      assert_equal 0, queue.length
      assert_equal 0, queue.num_waiting
      assert_equal :copy, queue.mode
      assert_predicate queue, :empty?
      refute_predicate queue, :full?
      refute_predicate queue, :closed?
      refute_predicate queue, :frozen?
      assert Ractor.shareable?(queue) if RUBY_ENGINE == "ruby"
      assert_raises(ArgumentError) { Queue.new(capacity: 0) }
      assert_raises(ArgumentError) { Queue.new(capacity: -1) }
      assert_raises(TypeError) { queue.dup }
      assert_raises(ArgumentError) { Queue.new(mode: :invalid) }
    end

    def test_modes_wrap_values_and_pop_operations_automatically_unwrap_them
      queue = Queue.new(mode: :local)
      local = ModePayload.new(:local)

      assert queue.push(local)
      assert_same local, queue.pop

      source = ModePayload.new(:original)

      assert queue.try_push(source, mode: :copy)
      source.value = :changed

      copy = queue.try_pop

      refute_same source, copy
      assert_equal :original, copy.value

      error = assert_raises(Ractor::IsolationError) do
        queue.push(ModePayload.new(:rejected), mode: :raise)
      end
      assert_match(/value is not Ractor-shareable/, error.message)
      assert_equal :local, queue.mode
    end

    def test_fifo_nil_and_aliases
      queue = Queue.new(capacity: 3)

      assert queue.push(:first)
      assert queue.enq(nil)
      assert queue.public_send(:<<, :third)
      assert_predicate queue, :full?
      assert_equal :first, queue.pop
      assert_nil queue.deq
      assert_equal :third, queue.shift
      assert_predicate queue, :empty?
    end

    def test_try_operations_and_fallbacks
      queue = Queue.new(capacity: 1)

      assert_equal(:empty, queue.try_pop { :empty })
      assert queue.try_push(nil)
      assert_equal :full, queue.try_push(:blocked) { :full }
      assert_nil queue.try_pop
      assert_nil queue.try_pop
      assert_predicate queue, :empty?
    end

    def test_queue_compatible_non_block_argument
      queue = Queue.new(capacity: 1)

      assert queue.enq(:value, true)

      error = assert_raises(ThreadError) { queue.push(:blocked, true) }

      assert_equal "queue full", error.message
      assert_equal :value, queue.deq(true)

      error = assert_raises(ThreadError) do
        queue.pop(true) { flunk "a non-blocking pop must not use the timeout fallback" }
      end

      assert_equal "queue empty", error.message
    end

    def test_unbounded_capacity
      queue = Queue.new(capacity: nil)

      assert_nil queue.capacity
      assert queue.wait_push(timeout: 0)
      10_000.times { assert queue.push(it, timeout: 0) }

      assert_equal 10_000, queue.size
      10_000.times { assert_equal it, queue.pop(timeout: 0) }
    end

    def test_timeouts_and_fallbacks
      queue = Queue.new(capacity: 1)

      assert_equal :empty, queue.pop(timeout: 0) { :empty }
      assert queue.push(:first, timeout: 0)
      refute queue.push(:second, timeout: 0)
      assert_equal :first, queue.pop(timeout: 0)
      assert_raises(ArgumentError) { queue.pop(timeout: -1) }
      assert_raises(ArgumentError) { queue.push(:value, timeout: Float::INFINITY) }
    end

    def test_blocking_pop_and_push
      queue = Queue.new(capacity: 1)
      consumer = Thread.new { queue.pop }
      sleep 0.01
      queue.push(:first)

      assert_equal :first, consumer.value

      queue.push(:second)
      producer = Thread.new { queue.push(:replacement) }
      sleep 0.01

      assert_equal :second, queue.pop
      assert producer.value
      assert_equal :replacement, queue.pop
    ensure
      consumer&.kill if consumer&.alive?
      producer&.kill if producer&.alive?
    end

    def test_wait_methods_and_num_waiting
      queue = Queue.new(capacity: 1)

      refute queue.wait_pop(timeout: 0)
      assert queue.wait_push(timeout: 0)

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

    def test_clear_and_close
      queue = Queue.new(capacity: 1)
      queue.push(:discarded)
      producer = Thread.new { queue.push(:replacement) }
      sleep 0.01

      assert_same queue, queue.clear
      assert producer.value
      assert_equal :replacement, queue.pop
      assert_same queue, queue.close
      assert_same queue, queue.close
      assert_predicate queue, :closed?
      assert_raises(ClosedQueueError) { queue.push(:value) }
      assert_raises(ClosedQueueError) { queue.pop }
      assert_raises(ClosedQueueError) { queue.wait_push }
      assert_raises(ClosedQueueError) { queue.wait_pop }
    ensure
      producer&.kill if producer&.alive?
    end

    def test_inspect_and_pretty_inspect
      queue = Queue.new(capacity: 2)

      assert_equal "#<Farce::Queue size=0 capacity=2>", queue.inspect
      assert_equal "#<Farce::Queue size=0 capacity=2>\n", queue.pretty_inspect

      queue.push(Object.new)

      assert_equal "#<Farce::Queue size=1 capacity=2>", queue.inspect
      assert_equal "#<Farce::Queue size=1 capacity=2>\n", queue.pretty_inspect

      unbounded = Queue.new(capacity: nil)

      assert_equal "#<Farce::Queue size=0>", unbounded.inspect
      assert_equal "#<Farce::Queue size=0>\n", unbounded.pretty_inspect

      queue.close

      assert_equal "#<Farce::Queue closed>", queue.inspect
      assert_equal "#<Farce::Queue closed>\n", queue.pretty_inspect
    end

    def test_works_across_cruby_ractors
      return unless RUBY_ENGINE == "ruby"
      queue = Queue.new

      result = Ractor.new(queue) do |shared|
        shared.push(:value)
        shared.pop
      end

      assert_equal :value, ractor_value(result)
    end

    def test_copies_unshareable_values_across_cruby_ractors
      return unless RUBY_ENGINE == "ruby"
      queue = Queue.new
      queue.push(ModePayload.new(:value))

      result = Ractor.new(queue) { |shared| shared.pop.value }

      assert_equal :value, ractor_value(result)
    end
  end
end
