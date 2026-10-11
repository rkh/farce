# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestTimerQueueEntry < Test
    include Helpers::InternalTestHelpers

    QUEUES = [TimerQueue, Strict::TimerQueue, Unshared::TimerQueue, Local::TimerQueue].freeze

    def test_push_returns_an_entry_with_the_queue_and_exact_clock
      QUEUES.each do |klass|
        queue = klass.new
        entry = queue.push(:value, delay: 60)

        assert_instance_of Abstract::TimerQueue::Entry, entry
        assert_same queue, entry.queue
        refute_respond_to entry, :value
        assert_equal queue.first_timestamp, entry.clock
        assert_predicate entry, :frozen?
        refute_respond_to entry, :value=
        refute_respond_to entry, :clock=
        refute_respond_to entry, :queue=
        assert_equal :value, queue.peek
      end
    end

    def test_try_push_returns_an_entry_and_parses_its_scheduled_clock
      QUEUES.each do |klass|
        queue = klass.new
        before = Clock.now + 60
        entry = queue.try_push(:value, timeout: 60)
        after = Clock.now + 60

        assert_instance_of Abstract::TimerQueue::Entry, entry
        assert_same queue, entry.queue
        refute_respond_to entry, :value
        assert_equal queue.first_timestamp, entry.clock
        assert_operator entry.clock, :>=, before
        assert_operator entry.clock, :<=, after
        assert queue.delete(entry)
      end
    end

    def test_queue_aliases_return_entries
      QUEUES.each do |klass|
        queue = klass.new
        entries = [queue.enq(:first), queue << :second]

        entries.each { |entry| assert_instance_of Abstract::TimerQueue::Entry, entry }
        assert_equal :first, queue.pop
        assert_equal :second, queue.pop
      end
    end

    def test_entries_cancel_relative_timers_without_reconstructing_the_timestamp
      QUEUES.each do |klass|
        queue = klass.new
        first = queue.push(:first, delay: 60)
        second = queue.push(:second, wait: 120)

        assert first.delete
        refute first.delete
        assert_equal :second, queue.peek
        assert queue.delete(second)
        refute queue.delete(second)
        assert_predicate queue, :empty?
      end
    end

    def test_entries_cancel_values_by_identity
      [Unshared::TimerQueue, Local::TimerQueue].each do |klass|
        queue = klass.new
        first = [:same]
        second = [:same]
        queue.push(first, at: 0.0)
        entry = queue.push(second, at: 0.0)

        assert entry.delete
        assert_same first, queue.pop
        queue.push(first, at: 0.0)
        entry = queue.push(second, at: 0.0)

        assert queue.delete(entry)
        assert_same first, queue.pop
      end
    end

    def test_failed_pushes_keep_the_existing_failure_contract
      QUEUES.each do |klass|
        queue = klass.new(capacity: 1)
        entry = queue.push(:first, delay: 60)

        assert_same false, queue.push(:full, timeout: 0)
        assert_raises(ThreadError) { queue.push(:full, true) }
        assert_same false, queue.try_push(:full)
        assert_equal :full, queue.try_push(:full) { :full }
        assert_equal 1, queue.size
        assert entry.delete
        assert_instance_of Abstract::TimerQueue::Entry, queue.try_push(:ready)
        assert_equal :ready, queue.pop
      end
    end

    def test_blocked_push_returns_the_entry_once_capacity_is_available
      queue = TimerQueue.new(capacity: 1)
      first = queue.push(:first, delay: 60)
      producer = Thread.new { queue.push(:second, delay: 120) }
      Timeout.timeout(5) { Thread.pass until queue.num_waiting.positive? }

      assert first.delete
      assert producer.join(5), "producer did not wake after cancellation"
      entry = producer.value

      assert_instance_of Abstract::TimerQueue::Entry, entry
      assert_same queue, entry.queue
      assert_equal :second, queue.peek
      assert_equal queue.first_timestamp, entry.clock
      assert entry.delete
    ensure
      queue&.close
      producer&.kill&.join
    end

    def test_entries_for_nil_and_false_can_be_deleted
      QUEUES.each do |klass|
        queue = klass.new
        first = queue.push(nil, delay: 60)
        second = queue.push(false, delay: 60)

        assert first.delete
        assert queue.delete(second)
        assert_predicate queue, :empty?
      end
    end

    def test_entries_no_longer_match_after_pop_or_clear
      QUEUES.each do |klass|
        queue = klass.new
        popped = queue.push(:ready)

        assert_equal :ready, queue.pop
        refute popped.delete
        cleared = queue.push(:cleared, delay: 60)
        queue.clear

        refute queue.delete(cleared)
      end
    end

    def test_entry_deletion_preserves_sealed_and_closed_queue_behavior
      QUEUES.each do |klass|
        queue = klass.new
        entry = queue.push(:value, delay: 60)
        queue.seal

        assert entry.delete
        assert_predicate queue, :closed?
        assert_raises(ClosedQueueError) { entry.delete }
      end
    end

    def test_delete_requires_at_for_values_and_preserves_explicit_nil_validation
      QUEUES.each do |klass|
        queue = klass.new

        assert_raises(ArgumentError) { queue.delete(:value) }
        assert_raises(TypeError) { queue.delete(:value, at: nil) }
      end
    end

    def test_an_entry_from_another_queue_cannot_cancel_a_matching_value
      QUEUES.each do |klass|
        queue = klass.new
        other = klass.new
        entry = other.push(:same, at: 0.0)
        queue.push(:same, at: 0.0)

        refute queue.delete(entry)
        assert_equal :same, queue.pop
        assert entry.delete
      end
    end

    def test_pushing_an_entry_returns_a_new_entry_and_pops_the_original
      QUEUES.each do |klass|
        queue = klass.new
        original = queue.push(:future, delay: 60)
        nested = queue.push(original)

        assert_instance_of Abstract::TimerQueue::Entry, nested
        refute_same original, nested
        refute_respond_to nested, :value
        assert_same original, queue.pop
        assert original.delete
      end
    end

    def test_an_explicit_timestamp_deletes_an_entry_stored_as_a_value
      QUEUES.each do |klass|
        queue = klass.new
        original = queue.push(:future, delay: 60)
        nested = queue.push(original, delay: 120)

        assert queue.delete(original, at: nested.clock)
        assert_equal :future, queue.peek
        assert original.delete
        assert_predicate queue, :empty?
      end
    end

    def test_direct_entries_do_not_freeze_or_unwrap_their_values
      [Unshared::TimerQueue, Local::TimerQueue].each do |klass|
        queue = klass.new
        value = []
        entry = queue.push(value)
        value << :changed

        assert_same value, queue.peek
        refute_predicate value, :frozen?
        assert entry.delete
      end
      queue = Strict::TimerQueue.new
      envelope = Envelope.new([], mode: :local)
      entry = queue.push(envelope)

      assert_same envelope, queue.peek
      assert entry.delete
    end

    def test_entries_preserve_transfer_modes
      %i[local copy marshal smart_copy].each do |mode|
        queue = TimerQueue.new(mode:)
        source = ModePayload.new(:original)
        entry = queue.push(source, delay: 60)
        source.value = :changed
        value = queue.peek

        if mode == :local
          assert_same source, value
          assert_equal :changed, value.value
        else
          refute_same source, value
          assert_equal :original, value.value
        end

        assert entry.delete
      end
    end

    def test_managed_entries_cancel_equal_values_by_the_stored_envelope_identity
      queue = TimerQueue.new(mode: :copy)
      queue.push(ModePayload.new(:same), at: 0.0)
      first = queue.peek
      second = queue.try_push(ModePayload.new(:same), at: 0.0)

      assert second.delete
      assert_same first, queue.pop
    end

    def test_managed_entry_cancellation_survives_payload_mutation
      queue = TimerQueue.new(mode: :copy)
      entry = queue.push(ModePayload.new(:original), delay: 60)
      queue.peek.value = :changed

      assert queue.delete(entry)
      assert_predicate queue, :empty?
    end

    def test_managed_entries_respect_per_push_mode_overrides
      queue = TimerQueue.new(mode: :raise)
      source = ModePayload.new(:original)
      entry = queue.push(source, mode: :copy)
      source.value = :changed

      assert_equal :original, queue.peek.value
      assert entry.delete
    end

    def test_managed_and_strict_entries_can_be_canceled_across_ractors
      return unless Internal.native_ractors?
      [TimerQueue, Strict::TimerQueue].each do |klass|
        %i[push try_push].each do |operation|
          queue = klass.new
          entry = queue.public_send(operation, :value, delay: 60)

          assert Ractor.shareable?(entry)
          worker = Ractor.new(entry) { |shared| shared.queue.delete(shared) }

          assert ractor_value(worker)
          assert_predicate queue, :empty?
        end
      end
    end

    def test_canceling_moved_and_local_entries_from_another_ractor_does_not_claim_them
      return unless Internal.native_ractors?
      %i[move local].each do |mode|
        %i[push try_push].each do |operation|
          queue = TimerQueue.new(mode:)
          source = ModePayload.new(:value)
          entry = queue.public_send(operation, source, delay: 60)
          envelope = queue.instance_variable_get(:@queue).peek

          assert Ractor.shareable?(entry)
          worker = Ractor.new(entry, &:delete)

          assert ractor_value(worker)
          refute_predicate envelope, :claimed? if mode == :move

          assert_equal :value, envelope.value.value
          assert_predicate queue, :empty?
        end
      end
    end

    def test_reading_a_moved_value_does_not_prevent_cancellation
      return unless Internal.native_ractors?
      queue = TimerQueue.new(mode: :move)
      queue.push(ModePayload.new(:first), at: 0.0)
      second = queue.push(ModePayload.new(:second), at: 0.0)

      assert_equal :first, queue.peek.value
      envelope = second.instance_variable_get(:@value)

      assert_equal :second, envelope.value.value
      assert second.delete
      assert_equal :first, queue.pop.value
    end

    def test_local_entry_deletion_uses_the_current_scope
      queue = Local::TimerQueue.new(scope: :fiber)
      entry = queue.push(:parent, delay: 60)
      child_result = Fiber.new do
        refute entry.delete
        child = queue.push(:child, delay: 60)
        [child.delete, queue.empty?]
      end.resume

      assert_equal [true, true], child_result
      assert_equal :parent, queue.peek
      assert entry.delete
    end
  end
end
