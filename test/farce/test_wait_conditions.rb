# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestWaitConditions < Test
    include Helpers::InternalTestHelpers

    def run(...) = Timeout.timeout(10) { super }

    def subjects
      [Atom.new(0), Strict::Atom.new(0), Map.new({ key: 0 }), Strict::Map.new({ key: 0 }),
       Counter.new(0), Local::Counter.new(0),
       Vector.new([0]), Strict::Vector.new([0]), Unshared::Vector.new([0]), Local::Vector.new([0])]
    end

    def arguments(subject)
      case subject
      when Abstract::Map then [:key]
      when Abstract::Vector then [0]
      else []
      end
    end

    def store(subject, value)
      case subject
      when Abstract::Map then subject[:key] = value
      when Abstract::Vector then subject[0] = value
      else subject.value = value
      end
    end

    def while_subjects
      subjects + [Local::Atom.new(0), Strict::WeakAtom.new(0), Unshared::WeakAtom.new(0),
                  Unshared::Map.new({ key: 0 }), Local::Map.new({ key: 0 }),
                  Strict::WeakKeyMap.new({ key: 0 }), Strict::WeakValueMap.new({ key: 0 }),
                  Strict::WeakMap.new({ key: 0 }), Unshared::WeakKeyMap.new({ key: 0 }),
                  Unshared::WeakValueMap.new({ key: 0 }), Unshared::WeakMap.new({ key: 0 })]
    end

    def test_wait_while_inverts_block_truthiness
      while_subjects.each do |subject|
        args = arguments(subject)

        assert_equal 0, subject.wait_while(*args, timeout: 0) { false }
        assert_equal 0, subject.wait_while(*args, timeout: 0) { nil }
        assert_nil subject.wait_while(*args, timeout: 0) { :waiting }
        assert_raises(LocalJumpError) { subject.wait_while(*args, timeout: 0) }
        assert_raises(RuntimeError) { subject.wait_while(*args) { raise "failed check" } }
      end
    end

    def test_wait_while_rechecks_changes
      while_subjects.each do |subject|
        seen = []
        result = subject.wait_while(*arguments(subject), timeout: 1) do |value|
          seen << value
          store(subject, value + 1) if value < 3
          value < 3
        end

        assert_equal 3, result
        assert_equal [0, 1, 2, 3], seen
      end
    end

    def test_wait_while_match_uses_case_equality
      while_subjects.each do |subject|
        args = arguments(subject)

        assert_equal 0, subject.wait_while_match(*args, String, timeout: 0)
        assert_nil subject.wait_while_match(*args, Integer, timeout: 0)
        store_value = method(:store)
        pattern = Object.new
        pattern.define_singleton_method(:===) do |value|
          store_value.call(subject, value + 1) if value < 3
          value < 3
        end

        assert_equal 3, subject.wait_while_match(*args, pattern, timeout: 1)
      end
    end

    def test_wait_while_value_preserves_timeout_fallbacks
      while_subjects.grep_v(Abstract::Vector).each do |subject|
        args = arguments(subject)

        assert_equal 0, subject.wait_while_value(*args, 1, timeout: 0)
        assert_nil subject.wait_while_value(*args, 0, timeout: 0)
        assert_equal :expired, subject.wait_while_value(*args, 0, timeout: 0) { :expired }
      end
    end

    def test_wait_while_value_uses_mode_aware_overrides
      [Atom.new(+"ready"), Map.new({ key: +"ready" })].each do |subject|
        args = arguments(subject)

        assert_equal "ready", subject.wait_while_value(*args, "busy", timeout: 0)
        assert_equal :expired, subject.wait_while_value(*args, +"ready", timeout: 0) { :expired }
      end
      value = +"ready"
      atom = Atom.new(value, mode: :local, compare_by_identity: true)

      assert_same value, atom.wait_while_value(value.dup, timeout: 0)
      assert_equal :expired, atom.wait_while_value(value, timeout: 0) { :expired }
    end

    def test_vector_wait_while_value
      [Vector, Strict::Vector, Unshared::Vector, Local::Vector].each do |type|
        vector = type.new(["ready"])

        assert_equal "ready", vector.wait_while_value(0, "busy", timeout: 0)
        assert_nil vector.wait_while_value(0, "ready", timeout: 0)
        assert_nil vector.wait_while_value(1, "ready", timeout: 0)
      end
      vector = Vector.new([+"ready"])

      assert_equal "ready", vector.wait_while_value(0, "busy", timeout: 0)
    end

    def test_vector_conditions_observe_absent_and_negative_indexes
      [Vector, Strict::Vector, Unshared::Vector, Local::Vector].each do |type|
        vector = type.new([1])

        assert_equal 1, vector.wait_until_value(-1, 1, timeout: 0)
        assert_equal 1, vector.wait_until_match(-1, Integer, timeout: 0)
        assert_equal 1, vector.wait_while_match(-1, String, timeout: 0)
        assert_nil vector.wait_until_match(1, NilClass, timeout: 0)
        seen = []
        result = vector.wait_until(1, timeout: 1) do |value|
          seen << value
          vector[1] = 2 if value.nil?
          value == 2
        end

        assert_equal 2, result
        assert_equal [nil, 2], seen
        assert_equal 2, vector.wait_while(-1, timeout: 0) { false }
      end
    end

    def test_counter_wait_while_boundaries
      [Counter.new(3), Local::Counter.new(3)].each do |counter|
        assert_nil counter.wait_while_above(2, timeout: 0)
        assert_equal 3, counter.wait_while_above(3, timeout: 0)
        assert_equal 3, counter.wait_while_above(4, timeout: 0)
        assert_equal 3, counter.wait_while_below(2, timeout: 0)
        assert_equal 3, counter.wait_while_below(3, timeout: 0)
        assert_nil counter.wait_while_below(4, timeout: 0)
        assert_equal 3, counter.wait_while_above("3", timeout: 0)
        assert_equal 3, counter.wait_while_below("3", timeout: 0)
      end
    end

    def test_signal_wait_while
      signal = Signal.new

      assert_same true, signal.wait_while(timeout: 0) { false }
      assert_same true, signal.wait_while(timeout: 0) { nil }
      assert_nil signal.wait_while(timeout: 0) { :waiting }
      assert_raises(LocalJumpError) { signal.wait_while(timeout: 0) }
      checks = 0
      result = signal.wait_while(timeout: 1) do
        checks += 1
        signal.broadcast if checks < 3
        checks < 3
      end

      assert_same true, result
      assert_equal 3, checks
    end

    def test_immediate_matches_and_timeouts
      subjects.each do |subject|
        args = arguments(subject)

        assert_equal 0, subject.wait_until_value(*args, 0, timeout: 0)
        assert_nil subject.wait_until_value(*args, 1, timeout: 0)
        assert_equal 0, subject.wait_until_match(*args, Integer, timeout: 0)
        assert_equal 0, subject.wait_until(*args, timeout: 0, &:zero?)
        assert_nil subject.wait_until_match(*args, String, timeout: 0)
        assert_raises(LocalJumpError) { subject.wait_until(*args) }
        assert_raises(ArgumentError) { subject.wait_until(*args, 0, timeout: 0) }
        [-1, Float::INFINITY, Float::NAN].each do |timeout|
          assert_raises(ArgumentError) { subject.wait_until_value(*args, 0, timeout:) }
        end
      end
    end

    def test_rechecks_changes_including_changes_during_the_predicate
      subjects.each do |subject|
        seen = []
        result = subject.wait_until(*arguments(subject), timeout: 1) do |value|
          seen << value
          store(subject, value + 1) if value < 3
          value == 3
        end

        assert_equal 3, result
        assert_equal [0, 1, 2, 3], seen
      end
    end

    def test_thread_wakes_waiter
      subjects.each do |subject|
        checked = Queue.new
        writer = Thread.new do
          checked.pop
          store(subject, 1)
        end

        assert_equal 1, subject.wait_until(*arguments(subject), timeout: 1) { |value|
          checked << true
          value == 1
        }
        writer.join
      ensure
        writer&.kill
        writer&.join
      end
    end

    def test_false_and_nil_are_values
      subjects.grep_v(Abstract::Counter).each do |subject|
        args = arguments(subject)
        store(subject, false)

        assert_same false, subject.wait_until_value(*args, false, timeout: 0)
        seen = []
        store(subject, nil)

        assert_nil subject.wait_until(*args, timeout: 0) { |value|
          seen << value
          true
        }
        assert_equal [nil], seen
      end
    end

    def test_identity_and_equality
      value = +"value"
      [Atom.new(value, mode: :local, compare_by_identity: true),
       Map.new({ key: value }, mode: :local, compare_values_by_identity: true),
       Vector.new([value], mode: :local, compare_by_identity: true)].each do |subject|
        args = arguments(subject)

        assert_same value, subject.wait_until_value(*args, value, timeout: 0)
        assert_nil subject.wait_until_value(*args, value.dup, timeout: 0)
        assert_same value, subject.wait_until_match(*args, /value/, timeout: 0)
      end
      assert_equal value, Atom.new(value).wait_until_value(value.dup, timeout: 0)
    end

    def test_timeout_does_not_treat_nil_as_a_changed_value
      subjects.each do |subject|
        seen = []

        assert_nil subject.wait_until(*arguments(subject), timeout: 0.001) { |value|
          seen << value
          value.nil?
        }
        assert_equal [0], seen
      end
    end

    def test_counter_mutations_wake_all_blocked_waiters
      mutations = [->(counter) { counter.store(1) }, ->(counter) { counter.swap(1) },
                   lambda(&:increment), lambda(&:decrement),
                   ->(counter) { counter.compare_and_set(0, 1) }]
      mutations.each do |mutate|
        counter = Counter.new
        signal = counter.send(:change_signal)
        waiters = Array.new(2) { Thread.new { counter.wait_until_changed(0, timeout: 2) } }
        Thread.pass until signal.num_waiting == 2
        mutate.call(counter)

        assert_equal [counter.value, counter.value], waiters.map(&:value)
        assert_equal 0, signal.num_waiting
      ensure
        waiters&.each(&:kill)
        waiters&.each(&:join)
      end
    end

    def test_counter_wait_across_ractors_and_gc
      counter = Counter.new
      signal = counter.send(:change_signal)
      worker = Ractor.new(counter) { |shared| shared.wait_until_above(0, timeout: 2) }
      Thread.pass until signal.num_waiting == 1
      GC.start
      GC.compact if GC.respond_to?(:compact)
      counter.increment

      assert_equal 1, ractor_value(worker)
    end

    def test_counter_wait_with_scheduled_fibers
      return unless Fiber.respond_to?(:set_scheduler)
      scheduler = Helpers::QueueTestScheduler.new
      Fiber.set_scheduler(scheduler)
      counter = Counter.new
      received = []
      Fiber.schedule { received << counter.wait_until_value(1, timeout: 1) }
      Fiber.schedule { counter.increment }
      Fiber.set_scheduler(nil)

      assert_equal [1], received
      assert_operator scheduler.io_wait_calls, :>=, 1
    ensure
      Fiber.set_scheduler(nil) if Fiber.respond_to?(:set_scheduler)
    end

    def test_normalized_keys_and_missing_entries
      map = Map.new(normalize_keys: :to_sym)
      seen = []
      result = map.wait_until("key", timeout: 1) do |value|
        seen << value
        map["key"] = 1 if value.nil?
        value == 1
      end

      assert_equal 1, result
      assert_equal [nil, 1], seen
      assert_equal 1, map.wait_until_match("key", Integer, timeout: 0)
    end

    def test_counter_wait_implementation_is_shared
      [Counter.new, Local::Counter.new].each do |counter|
        assert_equal Abstract::Counter, counter.method(:wait_until_changed).owner
        refute_respond_to counter, :change_signal
      end
    end

    def test_value_wait_rechecks_after_intermediate_changes
      subjects.each do |subject|
        checked = Queue.new
        object = Object.new
        object.define_singleton_method(:==) do |value|
          checked << value
          value == 2
        end
        writer = Thread.new do
          checked.pop
          store(subject, 1)
          checked.pop
          store(subject, 2)
        end

        assert_equal 2, subject.wait_until_value(*arguments(subject), object, timeout: 1)
        writer.join
      ensure
        writer&.kill
        writer&.join
      end
    end

    def test_counter_bounds
      [Counter.new(3), Local::Counter.new(3)].each do |counter|
        assert_equal 3, counter.wait_until_below(4, timeout: 0)
        assert_equal 3, counter.wait_until_above(2, timeout: 0)
        assert_nil counter.wait_until_below(3, timeout: 0)
        assert_nil counter.wait_until_above(3, timeout: 0)
        assert_equal :timeout, counter.wait_until_changed(3, timeout: 0) { :timeout }
        assert_equal 3, counter.dup.wait_until_value(3, timeout: 0)
      end
    end

    def test_one_timeout_budget_covers_repeated_checks_and_waits
      now = 0.0
      timeouts = []
      subject = Struct.new(:value).new(0)
      subject.define_singleton_method(:wait_until_changed) do |_, timeout:|
        timeouts << timeout
        now += 0.25
        self.value += 1
      end
      original_now = Clock.method(:now)
      Clock.define_singleton_method(:now) { now }
      result = Internal.wait_until(subject, timeout: 1) do
        now += 0.25
        false
      end

      assert_nil result
      assert_equal [0.75, 0.25], timeouts
    ensure
      if original_now
        Clock.singleton_class.remove_method(:now)
        Clock.define_singleton_method(:now, original_now)
      end
    end

    def test_predicate_time_counts_toward_timeout
      subject = Atom.new(0)
      calls = 0

      assert_nil subject.wait_until(timeout: 0.001) {
        calls += 1
        sleep 0.002
        false
      }
      assert_equal 1, calls
    end
  end
end
