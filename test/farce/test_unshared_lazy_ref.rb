# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestUnsharedLazyRef < Test
    def test_defers_and_delegates_to_mutable_local_result
      calls = []
      result = []
      reference = Unshared::LazyRef.new do
        calls << :called
        result
      end

      assert_kind_of Unshared::Lazy, Reference.deref(reference)
      assert_empty calls
      reference.push(:item)

      assert_same result, reference.itself
      assert_equal [:item], result
      assert_equal [:called], calls
    end

    def test_accepts_class_proc_and_bound_factories
      result = []
      reference = Unshared::LazyRef.new(Array)
      reference.push(:item)

      assert_equal [:item], reference.to_a
      assert_same result, Unshared::LazyRef.new(-> { result }).itself
      assert_same result, Unshared::LazyRef.new(self: result) { self }.itself
    end

    def test_freeze_resolves_target_and_copies_keep_evaluation
      calls = []
      reference = Unshared::LazyRef.new do
        calls << :called
        []
      end
      duplicate = reference.dup

      refute reference.frozen? # rubocop:disable Minitest/RefutePredicate -- Avoid resolving the lazy target.
      assert_empty calls
      assert_same reference, reference.freeze
      assert_predicate reference, :frozen?
      assert_same reference.itself, duplicate.itself
      assert_raises(FrozenError) { duplicate.push(:item) }
      assert_equal [:called], calls
    end

    def test_caches_nil_and_false_and_retries_failures
      [nil, false].each do |result|
        calls = 0
        reference = Unshared::LazyRef.new do
          calls += 1
          raise "not ready" if calls == 1
          result
        end

        assert_raises(RuntimeError) { reference.to_s }
        assert_equal result.to_s, reference.to_s
        assert_equal result.to_s, reference.to_s
        assert_equal 2, calls
      end
    end

    def test_rejects_modes_and_conflicting_factories
      assert_raises(ArgumentError) { Unshared::LazyRef.new(Array, mode: :copy) }
      assert_raises(ArgumentError) { Unshared::LazyRef.new(Array) { [] } }
    end
  end
end
