# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestLazyRef < Test
    include Helpers::InternalTestHelpers

    def reference_class = LazyRef
    def lazy_class = Lazy

    def test_defers_initialization_until_delegation_and_caches_the_result
      calls = Counter.new
      reference = reference_class.new do
        calls.increment
        "hello"
      end

      assert_kind_of lazy_class, Reference.deref(reference)
      assert_equal 0, calls.value
      assert_equal "HELLO", reference.upcase
      assert_equal 5, reference.length
      assert_equal 1, calls.value
    end

    def test_accepts_class_and_proc_factories
      assert_predicate reference_class.new(Counter), :zero?
      assert_equal :ready, reference_class.new(-> { :ready }).itself
    end

    def test_forwards_the_self_option_to_the_block
      reference = reference_class.new(self: 40) { self + 2 }

      assert_equal 42, reference.itself
    end

    def test_caches_nil_and_false
      [nil, false].each do |result|
        calls = Counter.new
        reference = reference_class.new do
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
      reference = reference_class.new do
        raise "not ready" if calls.increment == 1
        :ready
      end

      assert_raises(RuntimeError) { reference.to_s }
      assert_equal "ready", reference.to_s
      assert_equal "ready", reference.to_s
      assert_equal 2, calls.value
    end

    def test_rejects_a_factory_and_block_together
      assert_raises(ArgumentError) { reference_class.new(Counter) { 42 } }
    end

    def test_computes_once_across_ractors
      calls = Counter.new
      reference = reference_class.new do
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
