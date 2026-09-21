# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestLocalCounter < Test
    include Helpers::InternalTestHelpers

    def test_initialization_and_validation
      counter = Local::Counter.new("7")

      assert_kind_of Abstract::Counter, counter
      assert_kind_of Numeric, counter
      assert_equal :ractor, counter.scope
      assert_equal 7, counter.initial
      assert_equal 7, counter.value
      refute_predicate counter, :frozen?
      assert_predicate counter, :ractor_shareable?
      assert Ractor.shareable?(counter)
      assert_raises(FrozenError) { counter.send(:initialize, 8) }
      assert_equal 7, counter.initial
      assert_raises(ArgumentError) { Local::Counter.new(scope: :global) }
      assert_raises(TypeError) { Local::Counter.new(Object.new) }
      assert_raises(ArgumentError) { Local::Counter.new("invalid") }
      assert_raises(RangeError) { Local::Counter.new(2**63) } if RUBY_ENGINE == "ruby"
    end

    def test_operations_and_numeric_interface
      counter = Local::Counter.new(7)

      assert_same counter, counter.increment("3")
      assert_same counter, counter.add(2)
      assert_same counter, counter.decrement(1)
      assert_same counter, counter.subtract(2)
      assert_same counter, counter.remove
      assert_equal 8, counter.get
      assert_equal 8, counter.swap(4)
      assert_equal 5, counter.store(5)
      assert_equal 5, counter.value
      assert counter.compare_and_set(5, 6)
      refute counter.compare_and_set(5, 9)
      assert counter.increment_if_below(7)
      refute counter.increment_if_below(7)
      assert counter.decrement_if_above(6)
      refute counter.decrement_if_above(6)
      assert_equal 8, counter + 2
      assert_equal 8, 2 + counter
      assert_equal 6, counter.to_i
      assert_equal 6, counter.unwrap
      assert_equal "#<Farce::Local::Counter 6>", counter.inspect
      assert_same counter, counter.reset
      assert_equal 7, counter.value
    end

    def test_fiber_and_thread_isolation_and_reset
      %i[fiber thread].each do |scope|
        counter = Local::Counter.new(5, scope:)
        counter.increment(10)
        work = proc do
          before = counter.value
          counter.increment(3)
          counter.reset
          [before, counter.value]
        end
        result = scope == :fiber ? Fiber.new(&work).resume : Thread.new(&work).value

        assert_equal [5, 5], result
        assert_equal 15, counter.value
      end
    end

    def test_ractor_isolation
      counter = Local::Counter.new(5)
      counter.increment(10)
      worker = Ractor.new(counter) do |local|
        before = local.value
        local.increment(3)
        after = local.value
        local.reset
        [before, after, local.value]
      end

      assert_equal [5, 8, 5], ractor_value(worker)
      assert_equal 15, counter.value
    end

    def test_thread_group_scope
      counter = Local::Counter.new(5, scope: :thread_group)
      group = ThreadGroup.new
      counter.increment
      result = Thread.new do
        before = counter.value
        group.add(Thread.current)
        initial = counter.value
        Thread.new { counter.increment }.join
        [before, initial, counter.value]
      end.value

      assert_equal [6, 5, 6], result
      assert_equal 6, counter.value
    end

    def test_fiber_storage_inheritance
      counter = Local::Counter.new(5, scope: :fiber_storage)
      counter.increment

      assert_equal 7, Fiber.new { counter.increment.value }.resume
      assert_equal 5, Fiber.new(storage: {}) { counter.value }.resume
      assert_equal 7, counter.value
    end

    def test_shared_scopes_preserve_atomic_updates_and_bounds
      %i[ractor thread_group].each do |scope|
        counter = Local::Counter.new(scope:)
        workers = 8.times.map { Thread.new { 500.times { counter.increment } } }
        workers.each(&:value)

        assert_equal 4_000, counter.value
        workers = 8.times.map do
          Thread.new { 1_000.times.count { counter.decrement_if_above(0) } }
        end

        assert_equal 4_000, workers.sum(&:value)
        assert_equal 0, counter.value
      end
    end
  end
end
