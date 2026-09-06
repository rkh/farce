# frozen_string_literal: true

require_relative "../setup"

module Farce
  class TestQueueVariants < Test
    include Helpers::InternalTestHelpers

    SHAPES = %i[Queue PriorityQueue TimerQueue].freeze
    NAMESPACES = [Strict, Unshared].freeze

    def test_hierarchy_and_removed_name
      refute Farce.const_defined?(:StrictQueue, false)
      [Farce, *NAMESPACES].each do |namespace|
        SHAPES.each do |shape|
          klass = namespace.const_get(shape)
          base = shape == :Queue ? Abstract::Queue : Abstract.const_get(shape)

          assert_equal base, klass.superclass
          assert_kind_of Abstract::Queue, klass.new
        end
      end

      assert_equal Abstract::Queue, Abstract::PriorityQueue.superclass
      assert_equal Abstract::Queue, Abstract::TimerQueue.superclass
    end

    def test_unshared_fiber_wait_configuration
      SHAPES.each do |shape|
        klass = Unshared.const_get(shape)
        default = Internal.native_ractors? ? (Internal::UNSHARED_FIBER_IO ? :io : :block) : :auto

        assert_equal default, klass.new.fiber_wait
        %i[auto io block].each do |fiber_wait|
          queue = klass.new(fiber_wait:)
          expected = Internal.native_ractors? && fiber_wait != :auto ? fiber_wait : default

          assert_equal expected, queue.fiber_wait
          refute_respond_to queue, :fiber_wait=
          refute Ractor.shareable?(queue)
          assert queue.push(:value)
          assert_equal :value, queue.pop
        end
        [nil, true, false, :unknown, "io", Object.new].each do |fiber_wait|
          assert_raises(ArgumentError) { klass.new(fiber_wait:) }
        end
        [Farce, Strict].each do |namespace|
          assert_raises(ArgumentError) { namespace.const_get(shape).new(fiber_wait: :block) }
        end
      end
    end

    def test_direct_values_and_envelopes_preserve_identity
      NAMESPACES.each do |namespace|
        SHAPES.each do |shape|
          queue = namespace.const_get(shape).new(capacity: 8)
          envelope = Envelope.new(ModePayload.new(:payload), mode: :local)
          values = [nil, false, :symbol, 1.5, [:frozen].freeze, envelope]

          values.each { |value| assert queue.push(value) }
          values.each { |value| value.nil? ? assert_nil(queue.pop) : assert_same(value, queue.pop) } # rubocop:disable Style/CombinableLoops

          assert_same(:empty, queue.try_pop { :empty })
          assert_nil queue.pop(timeout: 0)
          assert_equal 0, queue.num_waiting
          assert_raises(TypeError) { queue.dup }
          assert_raises(TypeError) { queue.clone }
        end
      end
    end

    def test_strict_rejects_unshareable_values_even_when_full
      SHAPES.each do |shape|
        queue = Strict.const_get(shape).new(capacity: 1)
        value = ModePayload.new(:mutable)

        assert Ractor.shareable?(queue)
        assert_raises(Ractor::IsolationError) { queue.push(value) }
        assert_raises(Ractor::IsolationError) { queue.try_push(value) }
        assert queue.push(:first)
        assert_raises(Ractor::IsolationError) { queue.push(value, true) }
        assert_raises(Ractor::IsolationError) { queue.try_push(value) }
        assert_equal :first, queue.pop
        assert_equal :mutable, value.value
      end
    end

    def test_strict_priority_rejects_unshareable_priorities
      queue = Strict::PriorityQueue.new
      priority = ModePayload.new(:priority)
      assert_raises(Ractor::IsolationError) { queue.push(:value, priority:) }
      assert_raises(Ractor::IsolationError) { queue.try_push(:value, priority:) }
      assert_raises(Ractor::IsolationError) { Strict::PriorityQueue.new(default_priority: priority) }
      assert_predicate queue, :empty?
    end

    def test_unshared_accepts_mutable_values_and_cannot_be_shared
      SHAPES.each do |shape|
        queue = Unshared.const_get(shape).new
        value = [Object.new, +"mutable"]

        refute Ractor.shareable?(queue)
        assert queue.push(value)
        value << :changed

        assert_same value, queue.pop
        assert_equal :changed, value.last
        refute_predicate value, :frozen?
        next unless Internal.native_ractors?
        assert_raises(Ractor::Error, NoMethodError) { Ractor.make_shareable(queue) }
        refute Ractor.shareable?(queue)
      end
    end

    def test_unshared_string_priorities_are_snapshotted
      queue = Unshared::PriorityQueue.new
      priority = +"b"
      value = Object.new
      queue.push(value, priority:)
      priority.replace("a")

      assert_equal "b", queue.first_priority
      assert_predicate queue.first_priority, :frozen?
      refute_same priority, queue.first_priority
      assert_same value, queue.pop
    end

    def test_modes_are_not_accepted_by_direct_queues
      NAMESPACES.each do |namespace|
        SHAPES.each do |shape|
          klass = namespace.const_get(shape)
          assert_raises(ArgumentError) { klass.new(mode: :copy) }
          queue = klass.new
          error = shape == :TimerQueue ? NoMethodError : ArgumentError
          assert_raises(error) { queue.push(:value, mode: :copy) }
          assert_raises(error) { queue.try_push(:value, mode: :copy) }
          assert_predicate queue, :empty?
        end
      end
    end

    def test_float_priority_ordering_and_fifo_ties
      NAMESPACES.each do |namespace|
        %i[ascending descending].each do |order|
          queue = namespace::PriorityQueue.new(order:)
          random = Random.new(25)
          entries = Array.new(1000) { |i| [random.rand(20) / 4.0, i] }
          entries.each { |priority, value| queue.push(value, priority:) }
          expected = entries.sort_by { |priority, value| [order == :ascending ? priority : -priority, value] }

          expected.each { |entry| assert_equal entry.last, queue.pop }
          assert_predicate queue, :empty?
        end
      end
    end

    def test_exact_deletion_and_identity_with_mutable_values
      %i[PriorityQueue TimerQueue].each do |shape|
        queue = Unshared.const_get(shape).new
        options = shape == :TimerQueue ? { at: 0.0 } : { priority: 0.0 }
        first = [1]
        second = [1]
        queue.push(first, **options)
        queue.push(second, **options)

        assert queue.delete(second, **options, compare_by_identity: true)
        assert_same first, queue.peek
        assert queue.delete([1], **options)
        refute queue.delete(first, **options)
      end
    end

    def test_bounded_handoff_between_threads
      NAMESPACES.each do |namespace|
        SHAPES.each do |shape|
          queue = namespace.const_get(shape).new(capacity: 1)
          consumer = Thread.new { 200.times.map { queue.pop } }
          producer = Thread.new { 200.times { |i| queue.push(i) } }

          assert producer.join(5), "producer stuck for #{queue.class}"
          assert consumer.join(5), "consumer stuck for #{queue.class}"
          assert_equal (0...200).to_a, consumer.value
          assert_equal 0, queue.num_waiting
        ensure
          queue&.close
          producer&.kill
          consumer&.kill
        end
      end
    end

    def test_clear_and_close_wake_waiters
      NAMESPACES.each do |namespace|
        SHAPES.each do |shape|
          queue = namespace.const_get(shape).new(capacity: 1)
          queue.push(:first)
          producer = Thread.new { queue.push(:second) }
          Timeout.timeout(5) { Thread.pass until queue.num_waiting.positive? }
          queue.clear

          assert producer.join(5)
          assert_equal :second, queue.pop
          consumer = Thread.new do
            queue.pop
          rescue ClosedQueueError
            :closed
          end
          Timeout.timeout(5) { Thread.pass until queue.num_waiting.positive? }
          queue.close

          assert consumer.join(5)
          assert_equal :closed, consumer.value
          assert_raises(ClosedQueueError) { queue.wait_pop(timeout: 0) }
          assert_raises(ClosedQueueError) { queue.wait_push(timeout: 0) }
        ensure
          producer&.kill
          consumer&.kill
        end
      end
    end

    def test_timers_wait_for_due_values_and_earlier_insertions
      NAMESPACES.each do |namespace|
        queue = namespace::TimerQueue.new
        queue.push(:future, delay: 60)

        assert_nil queue.try_pop
        refute queue.wait_pop(timeout: 0)
        consumer = Thread.new { queue.pop }
        Timeout.timeout(5) { Thread.pass until queue.num_waiting.positive? }
        queue.push(:ready, at: 0.0)

        assert consumer.join(5)
        assert_equal :ready, consumer.value
        assert_equal :future, queue.peek
        assert_equal 1, queue.size
      ensure
        queue&.close
        consumer&.kill
      end
    end

    def test_strict_queues_cross_ractors
      return unless Internal.native_ractors?
      SHAPES.each do |shape|
        queue = Strict.const_get(shape).new
        value = [:shared, shape].freeze
        queue.push(value)
        worker = Ractor.new(queue) { |shared| shared.push(shared.pop) }

        assert ractor_value(worker)
        assert_same value, queue.pop
      end
    end

    def test_mutable_values_survive_gc_and_compaction
      return unless GC.respond_to?(:verify_compaction_references)
      SHAPES.each do |shape|
        queue = Unshared.const_get(shape).new(capacity: nil)
        1000.times { |i| queue.push([i, i.to_s]) }
        GC.start
        GC.verify_compaction_references(double_heap: true, toward: :empty)
        1000.times do |i|
          value = queue.pop

          assert_equal [i, i.to_s], value
          value << :mutable
        end

        assert_predicate queue, :empty?
      end
    end
  end
end
