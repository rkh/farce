# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestCounterConcurrentCompatibility < Test
    include Helpers::InternalTestHelpers

    COUNTER_TYPES = [Counter, Local::Counter].freeze

    def test_update_yields_the_current_integer_and_returns_the_new_value
      COUNTER_TYPES.each do |type|
        counter = type.new(5)
        arguments = []
        result = counter.update do |*values|
          arguments << values
          values.first + 7
        end

        assert_equal [[5]], arguments, type.name
        assert_equal 12, result, type.name
        assert_equal 12, counter.value, type.name
        assert_equal 5, counter.initial, type.name
        assert_equal(12, counter.update { |value| value })
        assert_equal(0, counter.update { 0 })
        assert_equal(-3, counter.update { |value| value - 3 })
        assert_equal(-3, counter.value)
      end
    end

    def test_update_requires_a_block_and_preserves_state_after_block_errors
      COUNTER_TYPES.each do |type|
        counter = type.new(7)
        failure = RuntimeError.new("update failed")

        assert_raises(LocalJumpError) { counter.update }
        error = assert_raises(RuntimeError) { counter.update { raise failure } }

        assert_same failure, error
        assert_equal 7, counter.value, type.name
        assert_equal(8, counter.update { |value| value + 1 })
      end
    end

    def test_update_rejects_non_integer_results_without_storing_them
      COUNTER_TYPES.each do |type|
        counter = type.new(7)
        [nil, false, "8", 8.0, Object.new].each do |replacement|
          assert_raises(TypeError) { counter.update { replacement } }
          assert_equal 7, counter.value, type.name
        end

        assert_equal(8, counter.update { |value| value + 1 })
      end
    end

    def test_update_rejects_frozen_counters
      COUNTER_TYPES.each do |type|
        counter = type.new(7).freeze

        assert_raises(FrozenError) { counter.update { |value| value + 1 } }
        assert_equal 7, counter.value, type.name
        counter = type.new(7)

        assert_raises(FrozenError) do
          counter.update do |value|
            counter.freeze
            value + 1
          end
        end
        assert_equal 7, counter.value, type.name
      end
    end

    def test_update_rechecks_the_current_value_after_a_concurrent_write
      COUNTER_TYPES.each do |type|
        counter = type.new(1)
        entered = Thread::Queue.new
        release = Thread::Queue.new
        observed = []
        worker = Thread.new do
          counter.update do |value|
            observed << value
            if observed.size == 1
              entered << value
              release.pop
            end
            value + 10
          end
        end
        begin
          assert_equal 1, Timeout.timeout(5) { entered.pop }
          counter.store(5)
          release << true

          assert worker.join(5), "#{type} update did not finish"
          assert_equal 15, worker.value, type.name
          assert_equal [1, 5], observed, type.name
          assert_equal 15, counter.value, type.name
        ensure
          release << true
          worker.kill if worker.alive?
          worker.join
        end
      end
    end

    def test_concurrent_updates_do_not_lose_increments_or_return_stale_results
      COUNTER_TYPES.each do |type|
        counter = type.new
        ready = Thread::Queue.new
        start = Thread::Queue.new
        workers = 4.times.map do
          Thread.new do
            ready << true
            start.pop
            100.times.map { counter.update { |value| value + 1 } }
          end
        end
        begin
          Timeout.timeout(5) { workers.size.times { ready.pop } }
          workers.size.times { start << true }
          workers.each { assert it.join(5), "#{type} update did not finish" }
          returned_values = workers.flat_map(&:value)

          assert_equal (1..400).to_a, returned_values.sort, type.name
          assert_equal 400, counter.value, type.name
        ensure
          workers.each(&:kill)
          workers.each(&:join)
        end
      end
    end

    def test_update_preserves_native_integer_range_validation
      return unless RUBY_ENGINE == "ruby"

      COUNTER_TYPES.each do |type|
        [[(2**63) - 1, 1], [-(2**63), -1]].each do |initial, delta|
          counter = type.new(initial)

          assert_raises(RangeError) { counter.update { |value| value + delta } }
          assert_equal initial, counter.value, type.name
        end
      end
    end

    def test_local_update_only_changes_the_current_thread_or_fiber
      %i[thread fiber].each do |scope|
        counter = Local::Counter.new(5, scope:)
        counter.update { |value| value + 10 }
        work = proc { [counter.value, counter.update { |value| value + 2 }, counter.value] }
        result = scope == :thread ? Thread.new(&work).value : Fiber.new(&work).resume

        assert_equal [5, 7, 7], result, scope.to_s
        assert_equal 15, counter.value, scope.to_s
      end
    end

    def test_local_update_only_changes_the_current_ractor
      counter = Local::Counter.new(5)
      counter.update { |value| value + 10 }
      worker = Ractor.new(counter) do |local|
        [local.value, local.update { |value| value + 2 }, local.value]
      end

      assert_equal [5, 7, 7], ractor_value(worker)
      assert_equal 15, counter.value
    end

    def test_shared_update_is_atomic_across_ractors
      return unless Internal.native_ractors?

      counter = Counter.new
      workers = 4.times.map do
        Ractor.new(counter) do |shared|
          100.times { shared.update { |value| value + 1 } }
        end
      end
      workers.each { ractor_value(it) }

      assert_equal 400, counter.value
    end
  end
end
