# frozen_string_literal: true

require_relative "../setup"

module Farce
  class TestTimerQueue < Test
    include Helpers::InternalTestHelpers

    def teardown
      Fiber.set_scheduler(nil) if Fiber.respond_to?(:scheduler) && Fiber.scheduler
    end

    def test_is_an_unbounded_abstract_queue_by_default
      queue = TimerQueue.new

      assert_equal Abstract::TimerQueue, TimerQueue.superclass
      refute_operator TimerQueue, :<, PriorityQueue
      assert_instance_of Internal::PriorityQueue, queue.instance_variable_get(:@queue)
      assert_nil queue.capacity
      assert_equal Float::INFINITY, queue.max
      assert_equal :copy, queue.mode

      assert_predicate queue, :empty?
      assert_predicate queue, :frozen?
      assert Ractor.shareable?(queue) if RUBY_ENGINE == "ruby"

      refute_respond_to queue, :delete_identity
      refute_respond_to queue, :peek_priority
      assert_raises(ArgumentError) { TimerQueue.new(mode: :invalid) }
    end

    def test_modes_wrap_values_and_reads_automatically_unwrap_them
      queue = TimerQueue.new(mode: :local)
      local = ModePayload.new(:local)

      assert queue.push(local, at: Clock.now)
      assert_same local, queue.peek
      assert_same local, queue.pop

      source = ModePayload.new(:original)

      assert queue.try_push(source, at: Clock.now, mode: :copy)
      source.value = :changed

      copy = queue.try_pop

      refute_same source, copy
      assert_equal :original, copy.value

      assert_raises(Ractor::IsolationError) do
        queue.push(ModePayload.new(:rejected), at: Clock.now, mode: :raise)
      end
      assert_equal :local, queue.mode
    end

    def test_nonblocking_interface_observes_timestamp_and_capacity
      queue = TimerQueue.new(capacity: 1)
      future = Clock.now + 0.03

      assert_equal(:empty, queue.try_pop { :empty })
      assert queue.try_push(:future, at: future)
      assert_equal :full, queue.try_push(:blocked, at: Clock.now) { :full }
      assert_equal(:not_ready, queue.try_pop { :not_ready })
      assert_equal :future, queue.peek
      assert_equal 1, queue.size

      sleep([future - Clock.now, 0].max + 0.005)

      assert_equal :future, queue.try_pop
      assert_predicate queue, :empty?
    end

    def test_queue_compatible_non_block_argument_observes_readiness_and_capacity
      queue = TimerQueue.new(capacity: 2)
      future = Clock.now + 60

      assert_equal 2, queue.capacity
      assert_equal 2, queue.max

      assert queue.push(:future, true, at: future)
      assert queue.enq(:ready, true, at: Clock.now)

      error = assert_raises(ThreadError) { queue.push(:blocked, true, at: Clock.now) }

      assert_equal "queue full", error.message
      assert_equal :ready, queue.pop(true)

      error = assert_raises(ThreadError) do
        queue.deq(true) { flunk "a non-blocking pop must not wait for a future timer" }
      end

      assert_equal "queue empty", error.message
      assert_equal :future, queue.peek
      assert_equal 1, queue.size
    end

    def test_push_parses_fixed_time_options_with_clock
      queue = TimerQueue.new
      timestamp = Time.now + 1

      assert queue.push(:value, time: timestamp)
      assert_in_delta Clock.parse(time: timestamp), queue.first_timestamp, 0.000_001
      assert_in_delta Clock.parse(time: timestamp), queue.last_timestamp, 0.000_001
      assert_equal :value, queue.peek
    end

    def test_push_and_try_push_parse_relative_time_options_with_clock
      queue = TimerQueue.new(capacity: 1)
      before = Clock.now + 60

      assert queue.push(:delayed, delay: 60)

      after = Clock.now + 60

      assert_operator queue.first_timestamp, :>=, before
      assert_operator queue.first_timestamp, :<=, after
      refute queue.push(:blocked, timeout: 0, wait: 30)

      queue.clear
      before = Clock.now + 45

      assert queue.try_push(:timed, timeout: 45)

      after = Clock.now + 45

      assert_operator queue.first_timestamp, :>=, before
      assert_operator queue.first_timestamp, :<=, after
    end

    def test_push_rejects_multiple_or_unknown_time_options
      queue = TimerQueue.new

      assert_raises(TypeError) { queue.push(:value, at: Clock.now, delay: 1) }
      assert_raises(NoMethodError) { queue.try_push(:value, eventually: 1) }
    end

    def test_push_and_try_push_default_to_now
      queue = TimerQueue.new
      before = Clock.now

      assert queue.push(:first)
      assert queue.try_push(:second)
      assert_operator queue.first_timestamp, :>=, before
      assert_operator queue.last_timestamp, :>=, before
      assert_operator queue.first_timestamp, :<=, queue.last_timestamp
      assert_equal :first, queue.try_pop
      assert_equal :second, queue.try_pop
    end

    def test_overdue_is_false_when_empty
      queue = TimerQueue.new

      refute_predicate queue, :overdue?
      refute queue.overdue?(leeway: 60)
    end

    def test_overdue_tracks_the_earliest_timestamp_and_leeway
      queue = TimerQueue.new
      now = Clock.now
      queue.push(:future, at: now + 60)

      refute_predicate queue, :overdue?
      assert queue.overdue?(leeway: 120)

      queue.push(:past, at: now - 60)

      assert_predicate queue, :overdue?
      refute queue.overdue?(leeway: -120)
      assert_equal :past, queue.try_pop
      refute_predicate queue, :overdue?
      assert_equal :future, queue.peek
    end

    def test_overdue_by_tracks_the_earliest_timestamp_and_leeway
      queue = TimerQueue.new

      assert_nil queue.overdue_by

      now = Clock.now
      past = now - 60
      queue.push(:future, at: now + 60)

      assert_nil queue.overdue_by

      queue.push(:past, at: past)
      before = Clock.now
      overdue_by = queue.overdue_by
      after = Clock.now

      assert_operator overdue_by, :>=, before - past
      assert_operator overdue_by, :<=, after - past
      assert_nil queue.overdue_by(leeway: 120)
      assert_operator queue.overdue_by(leeway: 30), :>=, overdue_by

      assert_equal :past, queue.try_pop
      assert_nil queue.overdue_by
      assert_equal :future, queue.peek
    end

    def test_pop_waits_until_the_earliest_timestamp
      queue = TimerQueue.new
      started = Clock.now
      queue.push(:value, at: started + 0.03)

      assert_equal :value, queue.pop
      assert_operator Clock.now - started, :>=, 0.02
      assert_predicate queue, :empty?
    end

    def test_pop_timeout_leaves_a_future_item_in_the_queue
      queue = TimerQueue.new
      queue.push(:future, at: Clock.now + 1)

      assert_equal :fallback, queue.pop(timeout: 0.01) { :fallback }
      assert_equal :future, queue.peek
      assert_equal 1, queue.size
    end

    def test_an_earlier_push_replaces_a_blocked_pops_deadline
      queue = TimerQueue.new
      queue.push(:later, at: Clock.now + 1)
      consumer = Thread.new { queue.pop }
      sleep 0.01

      queue.push(:earlier, at: Clock.now + 0.02)

      assert consumer.join(1), "consumer did not wake for the earlier timer"
      assert_equal :earlier, consumer.value
      assert_equal :later, queue.peek
    ensure
      consumer&.kill if consumer&.alive?
    end

    def test_wait_pop_waits_for_readiness_without_consuming
      queue = TimerQueue.new
      queue.push(:value, at: Clock.now + 0.02)

      refute queue.wait_pop(timeout: 0)
      assert queue.wait_pop(timeout: 1)
      assert_equal :value, queue.peek
      assert_equal 1, queue.size
    end

    def test_num_waiting_tracks_a_future_timer
      queue = TimerQueue.new
      queue.push(:future, at: Clock.now + 1)
      consumer = Thread.new { queue.pop }

      Timeout.timeout(5) { Thread.pass until queue.num_waiting.positive? }

      assert_operator queue.num_waiting, :>=, 1

      queue.push(:ready, at: Clock.now)

      assert_equal :ready, consumer.value
    ensure
      queue&.close unless queue&.closed?
      consumer&.kill if consumer&.alive?
    end

    def test_equal_timestamps_remain_fifo
      queue = TimerQueue.new
      timestamp = Clock.now

      queue.push(:first, at: timestamp)
      queue.push(:second, at: timestamp)

      assert_equal :first, queue.pop
      assert_equal :second, queue.pop
    end

    def test_nil_is_a_valid_value
      queue = TimerQueue.new
      queue.push(nil, at: Clock.now)

      assert_nil queue.peek
      assert_equal 1, queue.size
      assert_nil queue.pop
      assert_predicate queue, :empty?
    end

    def test_delete_normalizes_timestamps_and_preserves_value_contracts
      queue = TimerQueue.new
      timestamp = Time.now
      first = +"same"
      second = +"same"
      candidate = +"same"
      if RUBY_ENGINE == "ruby"
        [first, second, candidate].each { Ractor.make_shareable(it) }
      else
        [first, second, candidate].each(&:freeze)
      end

      queue.push(first, at: timestamp)
      queue.push(second, at: timestamp)

      assert queue.delete(second, at: timestamp, compare_by_identity: true)
      assert_same first, queue.pop

      queue.push(first, at: timestamp)
      queue.push(second, at: timestamp)

      assert queue.delete(candidate, at: timestamp)
      assert_same second, queue.pop
    end

    def test_delete_compares_copied_values_without_exposing_envelopes
      queue = TimerQueue.new
      timestamp = Time.now

      queue.push(ModePayload.new(:same), at: timestamp)

      assert queue.delete(ModePayload.new(:same), at: timestamp)
      assert_predicate queue, :empty?
    end

    def test_identity_delete_can_match_the_value_returned_by_peek
      queue = TimerQueue.new
      timestamp = Time.now
      queue.push(ModePayload.new(:stored), at: timestamp)
      value = queue.peek

      assert queue.delete(value, at: timestamp, compare_by_identity: true)
      assert_predicate queue, :empty?
    end

    def test_clear_and_close_wake_blocked_pop
      queue = TimerQueue.new
      queue.push(:discarded, at: Clock.now + 1)
      consumer = Thread.new do
        queue.pop
      rescue StandardError => e
        e
      end
      sleep 0.01

      queue.clear
      sleep 0.01

      refute consumer.join(0), "clear should keep an empty pop blocked"
      queue.close

      assert consumer.join(1), "close did not wake the consumer"
      assert_instance_of ClosedQueueError, consumer.value
    ensure
      consumer&.kill if consumer&.alive?
    end

    def test_rejects_nan_timestamps
      queue = TimerQueue.new

      error = assert_raises(ArgumentError) { queue.push(:value, at: Float::NAN) }
      assert_equal "timestamp must not be NaN", error.message
    end

    def test_works_across_cruby_ractors
      return unless RUBY_ENGINE == "ruby"
      queue = TimerQueue.new

      result = Ractor.new(queue) do |shared|
        shared.push(:value, at: Farce::Clock.now)
        shared.pop
      end

      assert_equal :value, ractor_value(result)
    end

    def test_copies_unshareable_values_across_cruby_ractors
      return unless RUBY_ENGINE == "ruby"
      queue = TimerQueue.new
      queue.push(ModePayload.new(:value), at: Clock.now)

      result = Ractor.new(queue) { |shared| shared.pop.value }

      assert_equal :value, ractor_value(result)
    end

    def test_timed_pop_does_not_block_a_fiber_scheduler
      skip "Fiber schedulers are not supported" unless Fiber.respond_to?(:set_scheduler)
      scheduler = Helpers::QueueTestScheduler.new
      Fiber.set_scheduler(scheduler)
      queue = TimerQueue.new
      queue.push(:value, at: Clock.now + 0.1)
      events = []

      Fiber.schedule do
        events << :pop_started
        events << queue.pop
      end
      Fiber.schedule { events << :other_fiber }
      Fiber.set_scheduler(nil)

      assert_equal %i[pop_started other_fiber value], events
      assert_operator scheduler.io_wait_calls, :>=, 1
    end

    def test_earlier_push_wakes_a_scheduled_fiber
      skip "Fiber schedulers are not supported" unless Fiber.respond_to?(:set_scheduler)
      scheduler = Helpers::QueueTestScheduler.new
      Fiber.set_scheduler(scheduler)
      queue = TimerQueue.new
      queue.push(:later, at: Clock.now + 1)
      events = []

      Fiber.schedule do
        events << :pop_started
        events << queue.pop
      end
      Fiber.schedule do
        events << :producer_started
        Fiber.scheduler.kernel_sleep(0.01)
        queue.push(:earlier, at: Clock.now)
        events << :producer_finished
      end
      Fiber.set_scheduler(nil)

      assert_equal %i[pop_started producer_started producer_finished earlier], events
      assert_equal :later, queue.peek
      assert_operator scheduler.io_wait_calls, :>=, 1
    end
  end
end
