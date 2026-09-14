# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestLocalLazyRef < Test
    include Helpers::InternalTestHelpers

    def test_defers_initialization_and_retains_mutations
      calls = Counter.new
      reference = Local::LazyRef.new do
        calls.increment
        []
      end

      assert_kind_of Local::Lazy, Reference.deref(reference)
      assert_equal 0, calls.value
      reference.push(:item)

      assert_equal [:item], reference.to_a
      assert_equal 1, calls.value
    end

    def test_accepts_class_and_proc_factories
      reference = Local::LazyRef.new(Hash)
      reference[:key] = :value

      assert_equal :value, reference.fetch(:key)
      assert_empty Local::LazyRef.new(-> { [] })
    end

    def test_forwards_the_self_option_to_the_block
      reference = Local::LazyRef.new(self: :initial) { [self] }

      assert_equal [:initial], reference.to_a
    end

    def test_caches_nil_and_false
      [nil, false].each do |result|
        calls = Counter.new
        reference = Local::LazyRef.new do
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
      reference = Local::LazyRef.new do
        raise "not ready" if calls.increment == 1
        []
      end

      assert_raises(RuntimeError) { reference.push(:first) }
      reference.push(:second)

      assert_equal [:second], reference.to_a
      assert_equal 2, calls.value
    end

    def test_initializes_independently_in_each_fiber_scope
      calls = Counter.new
      reference = Local::LazyRef.new(scope: :fiber) do
        calls.increment
        []
      end
      reference.push(:parent)
      child = Fiber.new do
        before = reference.empty?
        reference.push(:child)
        [before, reference.to_a]
      end.resume

      assert_equal [true, [:child]], child
      assert_equal [:parent], reference.to_a
      assert_equal 2, calls.value
    end

    def test_thread_scope_is_shared_by_fibers_but_not_threads
      reference = Local::LazyRef.new(Array, scope: :thread)
      reference.push(:parent)

      assert_equal [:parent], Fiber.new { reference.to_a }.resume
      assert Thread.new { reference.empty? }.value
      assert_equal [:parent], reference.to_a
    end

    def test_default_scope_is_isolated_between_ractors
      calls = Counter.new
      reference = Local::LazyRef.new do
        calls.increment
        []
      end

      assert_equal 0, calls.value
      reference.push(:parent)
      worker = Ractor.new(reference) do |local|
        before = local.empty?
        local.push(:child)
        [before, local.to_a]
      end

      assert_equal [true, [:child]], ractor_value(worker)
      assert_equal [:parent], reference.to_a
      assert_equal 2, calls.value
    end

    def test_rejects_invalid_constructor_options
      assert_raises(ArgumentError) { Local::LazyRef.new(Array) { [] } }
      assert_raises(ArgumentError) { Local::LazyRef.new(Array, scope: :invalid) }
    end
  end
end
