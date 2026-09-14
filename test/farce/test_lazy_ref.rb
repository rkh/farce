# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestLazyRef < Test
    include Helpers::InternalTestHelpers

    def test_defers_initialization_until_delegation_and_caches_the_result
      calls = Counter.new
      reference = LazyRef.new do
        calls.increment
        "hello"
      end

      assert_kind_of Lazy, Reference.deref(reference)
      assert_equal 0, calls.value
      assert_equal "HELLO", reference.upcase
      assert_equal 5, reference.length
      assert_equal 1, calls.value
    end

    def test_accepts_class_and_proc_factories
      assert_predicate LazyRef.new(Counter), :zero?
      assert_equal :ready, LazyRef.new(-> { :ready }).itself
    end

    def test_forwards_the_self_option_to_the_block
      reference = LazyRef.new(self: 40) { self + 2 }

      assert_equal 42, reference.itself
    end

    def test_caches_nil_and_false
      [nil, false].each do |result|
        calls = Counter.new
        reference = LazyRef.new do
          calls.increment
          result
        end

        assert_predicate reference, :!
        assert_equal result.to_s, reference.to_s
        assert_equal 1, calls.value
      end
    end

    def test_retries_after_the_factory_raises
      calls = Counter.new
      reference = LazyRef.new do
        raise "not ready" if calls.increment == 1
        :ready
      end

      assert_raises(RuntimeError) { reference.to_s }
      assert_equal "ready", reference.to_s
      assert_equal "ready", reference.to_s
      assert_equal 2, calls.value
    end

    def test_rejects_a_factory_and_block_together
      assert_raises(ArgumentError) { LazyRef.new(Counter) { 42 } }
    end

    def test_computes_once_across_ractors
      calls = Counter.new
      reference = LazyRef.new do
        calls.increment
        "shared"
      end

      assert_equal 0, calls.value
      reference = Ractor.make_shareable(reference)
      workers = 4.times.map { Ractor.new(reference, &:upcase) }

      assert_equal(["SHARED"] * 4, workers.map { ractor_value(it) })
      assert_equal 1, calls.value
    end
  end
end
