# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestVector < Test
    include Helpers::InternalTestHelpers

    VECTOR_CLASSES = [Vector, Strict::Vector, Unshared::Vector].freeze

    def run(...) = Timeout.timeout(15) { super }

    def test_public_variants
      VECTOR_CLASSES.each do |klass|
        vector = klass.new

        assert_kind_of Abstract::Vector, vector
        assert_empty vector
        assert_equal 0, vector.length
        refute_predicate vector, :compare_by_identity?
        assert_equal klass != Unshared::Vector, vector.shareable_values?
        assert_equal klass != Unshared::Vector, vector.ractor_shareable?
        assert_equal klass != Unshared::Vector, Ractor.shareable?(vector)
      end

      assert_equal :copy, Vector.new.mode
    end

    def test_initialization_and_indexed_access
      VECTOR_CLASSES.each do |klass|
        source = [1, nil, 3]
        vector = klass.new(source)
        source.clear

        assert_equal 3, vector.size
        assert_equal 3, vector[-1]
        assert_nil vector[-4]
        assert_same false, vector.store(1, false, timeout: 0)
        assert_same false, vector.get(1, timeout: 0)
        assert_equal 5, vector[4] = 5
        assert_nil vector[3]
        assert_equal 5, vector.size
        assert_raises(IndexError) { vector[-6] = 0 }
        assert_raises(TypeError) { klass.new({}) }
        assert_raises(ArgumentError) { klass.new(compare_by_identity: nil) }
      end
    end

    def test_push_pop_swap_and_clear
      VECTOR_CLASSES.each do |klass|
        vector = klass.new

        assert_same vector, vector.push(:first, timeout: 0)
        assert_same vector, vector << :second
        assert_equal :second, vector.swap(-1, :replacement)
        assert_equal :replacement, vector.pop(timeout: 0)
        assert_equal :first, vector.pop
        assert_nil vector.pop(timeout: 0)
        assert_same vector, vector.clear
        assert_empty vector
      end
    end

    def test_atomic_operations_treat_nil_as_absent
      VECTOR_CLASSES.each do |klass|
        vector = klass.new([nil, false])

        assert_equal 1, vector.store_if_absent(0) { 1 }
        assert_same false, vector.store_if_absent(1) { flunk "false is present" }
        assert_equal 2, vector.upsert(0, 0) { it + 1 }
        assert_equal 3, vector.upsert(3, 3) { flunk "missing index" }
        assert_equal 4, vector.update(2) { |current|
          assert_nil current
          4
        }
        assert vector.compare_and_set(-1, 3, nil)
        assert vector.compare_and_set(3, nil, :present)
        refute vector.compare_and_set(4, nil, :missing, timeout: 0)
        refute vector.compare_and_set(-5, nil, :missing, timeout: 0)
        assert_equal 4, vector.size
        assert_raises(LocalJumpError) { vector.update(0) }
        assert_raises(LocalJumpError) { vector.store_if_absent(0) }
        assert_raises(LocalJumpError) { vector.upsert(0, 0) }
        assert_raises(RuntimeError) { vector.update(6) { raise "failed" } }
        assert_equal 4, vector.size
        assert_equal :recovered, vector.update(0) { :recovered }
      end
    end

    def test_comparison_modes
      VECTOR_CLASSES.each do |klass|
        original = shared_string("value")
        equal = shared_string("value")
        vector = klass.new([original])

        assert vector.compare_and_set(0, equal, :replaced)
        vector = klass.new([original], compare_by_identity: true)

        assert_predicate vector, :compare_by_identity?
        refute vector.compare_and_set(0, equal, :replaced)
        assert vector.compare_and_set(0, original, :replaced)
      end
    end

    def test_unshared_values_retain_identity
      value = Object.new
      vector = Unshared::Vector.new([value])

      assert_same value, vector[0]
      assert_same value, vector.store(1, value)
      assert_same value, vector.update(0) { it }
      assert_same value, vector.upsert(2, value) { flunk "missing index" }
      assert_same value, vector.store_if_absent(3) { value }
      assert_same value, vector.swap(0, nil)
      assert_same value, vector.pop
    end

    def test_managed_values_and_per_operation_modes
      value = Unshared::Vector.new
      vector = Vector.new(mode: :local)

      assert_same value, vector.store(0, value)
      assert_same value, vector.get(0)
      assert_same value, vector.store_if_absent(0) { flunk "existing value" }
      assert_same value, vector.update(0) { |current|
        assert_same value, current
        current
      }
      assert_same value, vector.upsert(0, nil) { it }
      assert_same value, vector.wait_until_non_nil(0, timeout: 0)
      assert_same value, vector.wait_until_changed(0, nil, timeout: 0)
      assert_same value, vector.swap(0, nil)
      assert_same vector, vector.push(value, mode: :local)
      assert_same value, vector.pop
      assert_raises(Ractor::IsolationError) { vector.store(0, value, mode: :raise) }
      assert_raises(ArgumentError) { Vector.new(mode: :invalid) }
    end

    def test_managed_copy_values_and_comparisons
      return unless Internal.native_ractors?

      original = [1]
      vector = Vector.new([original])
      original << 2
      first = vector[0]

      assert_equal [1], first
      first << 3

      assert_same first, vector.get(0)
      assert vector.compare_and_set(0, [1], [2])
      assert_equal [2], vector[0]
      assert_nil vector.wait_until_changed(0, [2], timeout: 0)
      assert_equal [2], vector.wait_until_changed(0, [1], timeout: 0)
      assert_equal [2, 3], vector.update(0) { it + [3] }
      assert_equal [2, 3], vector.pop
    end

    def test_managed_identity_comparison
      value = Unshared::Vector.new
      vector = Vector.new([value], mode: :local, compare_by_identity: true)

      refute vector.compare_and_set(0, Unshared::Vector.new, nil)
      assert_nil vector.wait_until_changed(0, value, timeout: 0)
      assert vector.compare_and_set(0, value, nil)
      assert_nil vector[0]
    end

    def test_failed_comparison_does_not_transfer_replacement
      vector = Vector.new([:original], mode: :raise)

      refute vector.compare_and_set(0, :wrong, Unshared::Vector.new)
      assert_equal :original, vector[0]
    end

    def test_strict_rejects_unshareable_values
      value = Unshared::Vector.new
      vector = Strict::Vector.new([nil])

      assert_raises(Ractor::IsolationError) { Strict::Vector.new([value]) }
      assert_raises(Ractor::IsolationError) { vector[0] = value }
      assert_raises(Ractor::IsolationError) { vector.store(0, value) }
      assert_raises(Ractor::IsolationError) { vector.push(value) }
      assert_raises(Ractor::IsolationError) { vector.swap(0, value) }
      assert_raises(Ractor::IsolationError) { vector.compare_and_set(0, nil, value) }
      assert_raises(Ractor::IsolationError) { vector.store_if_absent(0) { value } }
      assert_raises(Ractor::IsolationError) { vector.upsert(0, value) { nil } }
      assert_raises(Ractor::IsolationError) { vector.update(2) { value } }
      assert_equal 1, vector.size
      assert_nil vector[0]
    end

    def test_atomic_updates_across_threads
      VECTOR_CLASSES.each do |klass|
        vector = klass.new([0])
        threads = 4.times.map do
          Thread.new { 100.times { vector.update(0) { it + 1 } } }
        end
        threads.each(&:value)

        assert_equal 400, vector[0]
      end
    end

    def test_timeouts_during_updates
      VECTOR_CLASSES.each do |klass|
        vector = klass.new([1])
        entered = ::Queue.new
        release = ::Queue.new
        worker = Thread.new do
          vector.update(0) do
            entered << true
            release.pop
            2
          end
        end
        begin
          entered.pop

          assert_equal 1, vector[0]
          assert_nil vector.get(0, timeout: 0)
          assert_same false, vector.store(0, 3, timeout: 0)
          refute vector.push(3, timeout: 0)
          assert_nil vector.pop(timeout: 0)
          assert_nil vector.swap(0, 3, timeout: 0)
          refute vector.compare_and_set(0, 1, 3, timeout: 0)
          assert_nil vector.update(0, timeout: 0) { flunk "timed out" }
          assert_nil vector.upsert(0, 0, timeout: 0) { flunk "timed out" }
          assert_nil vector.store_if_absent(2, timeout: 0) { flunk "timed out" }
        ensure
          release << true
          worker.value
        end
      end
    end

    def test_wait_until_changed_waits_before_timing_out
      vector = Vector.new([:unchanged])

      assert_nil vector.wait_until_changed(0, :unchanged, timeout: 0.01)
      assert_equal :unchanged, vector[0]
    end

    def test_waiters_observe_changes
      VECTOR_CLASSES.each do |klass|
        vector = klass.new
        waiter = Thread.new { vector.wait_until_non_nil(2, timeout: 1) }
        vector[2] = :ready

        assert_equal :ready, waiter.value
        waiter = Thread.new { vector.wait_until_changed(2, :ready, timeout: 1) }
        vector[2] = false

        assert_same false, waiter.value
        assert_nil vector.wait_until_non_nil(0, timeout: 0)
        assert_nil vector.wait_until_changed(2, false, timeout: 0)
        assert_raises(ArgumentError) { vector.wait_until_changed(0, nil, timeout: -1) }
        assert_raises(ArgumentError) { vector.get(0, timeout: Float::INFINITY) }
      end
    end

    def test_managed_values_preserve_foreign_envelopes
      envelope = Envelope::Local.new(Unshared::Vector.new)
      vector = Vector.new([envelope])

      assert_same envelope, vector[0]
      assert_same envelope, vector.get(0)
      assert_same envelope, vector.update(0) { it }
      assert_same envelope, vector.pop
    end

    def test_shareable_transfer_modes
      return unless Internal.native_ractors?

      vector = Vector.new
      original = []
      copy = vector.store(0, original, mode: :shareable_copy)

      assert Ractor.shareable?(copy)
      refute_same original, copy
      refute_predicate original, :frozen?
      assert_same original, vector.store(1, original, mode: :make_shareable)
      assert Ractor.shareable?(original)
      assert_equal [:value], vector.update(1, mode: :make_shareable) { it + [:value] }
      assert Ractor.shareable?(vector[1])
    end

    def test_copy_and_move_between_ractors
      return unless Internal.native_ractors?

      %i[copy move].each do |mode|
        original = [:value]
        vector = Vector.new(mode:)
        vector.push(original)
        worker = Ractor.new(vector, &:pop)

        assert_equal [:value], ractor_value(worker)
        assert_empty vector
        assert_equal [:value], original if mode == :copy
      end
    end

    def test_managed_compare_and_set_under_contention
      vector = Vector.new([0])
      workers = 4.times.map do
        Thread.new do
          100.times do
            loop do
              current = vector[0]
              break if vector.compare_and_set(0, current, current + 1)
            end
          end
        end
      end
      workers.each(&:value)

      assert_equal 400, vector[0]
    end

    def test_shareable_vectors_work_across_ractors
      [Vector, Strict::Vector].each do |klass|
        vector = klass.new([0])
        workers = 2.times.map do
          Ractor.new(vector) { |shared| 100.times { shared.update(0) { it + 1 } } }
        end
        workers.each { ractor_value(it) }

        assert_equal 200, vector[0]
      end
    end
  end
end
