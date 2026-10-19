# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../../setup"
require "timeout"

module Farce
  module Internal
    class TestQueueTuning < Test
      def test_resize_preserves_wrapped_items_and_age_tracking
        [Queue, UnsharedQueue].each do |type|
          queue = type.new(capacity: 3, track_age: true)
          %i[a b c].each { |value| queue.push(value) }
          queue.pop
          queue.push(:d)
          generation = queue.generation
          timestamp = queue.oldest_enqueued_at
          queue.capacity = 1

          assert_equal generation, queue.generation
          assert_equal timestamp, queue.oldest_enqueued_at
          assert_equal(%i[b c d], 3.times.map do
            assert_same false, queue.try_push(:extra)
            queue.pop
          end)
          assert queue.try_push(:after)
          assert_equal :after, queue.pop
          queue.capacity = 4

          4.times { assert queue.try_push(:item) }
        end
      end

      def test_bounded_and_unbounded_switches
        [Queue, UnsharedQueue].each do |type|
          queue = type.new(capacity: 1)
          if Ractor.builtin?
            queue.capacity = nil

            20.times { assert queue.try_push(:item) }
            queue.capacity = 2

            refute queue.try_push(:extra)
            assert_equal(20, 20.times.count { queue.pop == :item })
            2.times { assert queue.try_push(:after) }
          else
            assert_raises(ArgumentError) { queue.capacity = nil }
            assert_equal 1, queue.capacity
            queue = type.new(capacity: nil)

            assert_raises(ArgumentError) { queue.capacity = 2 }
            assert_nil queue.capacity
          end
        end
      end

      def test_increasing_capacity_releases_a_waiting_producer
        queue = Queue.new(capacity: 1)
        queue.push(:first)
        ready = Farce::Queue.new
        producer = Thread.new do
          ready << true
          queue.push(:second)
        end

        assert ready.pop(timeout: 5)
        queue.capacity = 2

        assert producer.join(5)
        assert_equal(%i[first second], 2.times.map { queue.pop })
      ensure
        queue&.close
        producer&.kill&.join
      end

      def test_interrupt_wakes_all_waiters_without_removing_items
        [Queue, UnsharedQueue].each do |type|
          queue = type.new
          before = Object.new.freeze
          after = Object.new.freeze
          queue.interrupt(before, 0)
          ready = Farce::Queue.new
          waiters = 8.times.map do
            Thread.new do
              ready << true
              queue.pop_interruptible(before, nil)
            end
          end

          8.times { assert ready.pop(timeout: 5) }
          if GC.respond_to?(:verify_compaction_references)
            GC.verify_compaction_references(double_heap: true,
              toward: :empty)
          end
          queue.interrupt(after, 1)
          waiters.each do |waiter|
            assert waiter.join(5)
            assert_same false, waiter.value
          end
          queue.push(:retained)

          assert_same false, queue.pop_interruptible(before, 0)
          assert_equal :retained, queue.pop_interruptible(after, 0)
        ensure
          queue&.close
          waiters&.each { |waiter| waiter.kill.join }
        end
      end

      def test_an_awakened_fiber_can_wait_again_before_sibling_interrupts_are_acknowledged
        return unless Ractor.builtin?
        output, error, status = ruby_isolated(<<~RUBY)
          require "farce"
          require "timeout"
          require "helpers/queue_test_scheduler"
          class ReadyScheduler < Helpers::QueueTestScheduler
            def io_wait(io, events, duration)
              ready = Fiber.blocking { IO.select([io], nil, nil, 0) }
              return IO::READABLE if ready
              super
            end
          end
          [false, true].each do |mixed|
            queue = Farce.const_get(:Internal)::Queue.new
            before = Object.new.freeze
            after = Object.new.freeze
            queue.interrupt(before, 0)
            ready = Farce::Queue.new
            completed = Farce::Queue.new
            scheduler = Farce::Scheduler.create(Thread) { ReadyScheduler.new }
            2.times do |index|
              scheduler.schedule(queue, before, after, ready, completed, mixed && index.zero?) do |input, old, current,
                                                                                                started, output, ordinary|
                started << true
                if ordinary
                  output << input.pop
                else
                  output << input.pop_interruptible(old, nil)
                  output << input.pop_interruptible(current, nil)
                end
              end
            end
            2.times { abort "fiber did not start" unless ready.pop(timeout: 2) }
            queue.interrupt(after, 1)
            (mixed ? 1 : 2).times do
              abort "interrupted fiber starved" unless completed.pop(timeout: 2) == false
            end
            2.times { queue.push(:finished) }
            2.times { abort "task lost" unless completed.pop(timeout: 2) == :finished }
            scheduler.close
            Timeout.timeout(2) { sleep 0.001 until scheduler.state == :closed }
          end
          puts "done"
        RUBY

        assert_predicate status, :success?, error
        assert_equal "done\n", output
        assert_empty error
      end

      def test_public_fifo_queues_and_schedulers_resize_their_backing_queue
        [Farce::Queue, Farce::Strict::Queue, Farce::Unshared::Queue, Farce::Local::Queue].each do |type|
          queue = type.new(capacity: 1)
          queue.capacity = 3

          assert_equal 3, queue.capacity
          3.times { |value| assert queue.try_push(value) }
          refute queue.try_push(:extra)
          assert_equal [0, 1, 2], Array.new(3) { queue.pop }
          queue.close
        end
        [Farce::Scheduler, Farce::Unshared::Scheduler, Farce::Local::Scheduler].each do |type|
          scheduler = type.new(capacity: 1)
          scheduler.capacity = 3

          assert_equal 3, scheduler.capacity
          assert_equal :initialized, scheduler.state
          scheduler.close
        end
      end

      def test_late_notifications_cannot_replace_a_newer_token
        queue = Queue.new
        older = Object.new.freeze
        newer = Object.new.freeze
        queue.interrupt(newer, 2)
        queue.interrupt(older, 1)

        assert_same false, queue.pop_interruptible(older, 0)
        assert_equal :empty, queue.pop_interruptible(newer, 0) { :empty }
      end
    end
  end
end
