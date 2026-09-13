# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestLocalRef < Test
    include Helpers::InternalTestHelpers

    def test_accepts_an_omitted_default
      ref = LocalRef.new

      assert_nil ref.__getobj__
      assert_equal "", ref.to_s
    end

    def test_delegates_to_the_default
      ref = LocalRef.new("hello")

      assert_equal "HELLO", ref.upcase
      assert_respond_to ref, :upcase
      refute_respond_to ref, :not_a_string_method
      assert_raises(NoMethodError) { ref.not_a_string_method }
    end

    def test_initializer_is_lazy
      calls = Counter.new
      ref = LocalRef.new do
        calls.increment
        []
      end

      assert_equal 0, calls.value
      ref << :value

      assert_equal [:value], ref.__getobj__
      assert_equal 1, calls.value
    end

    def test_forwards_arguments_keywords_and_blocks
      ref = LocalRef.new { { answer: 42 } }

      assert_equal 42, ref.fetch(:answer)
      assert_equal "unknown", ref.fetch(:unknown, &:to_s)
      assert_equal({ answer: 42, extra: 1 }, ref.merge(extra: 1))
    end

    def test_replaces_the_current_target
      ref = LocalRef.new { raise "initializer should not run" }
      target = []
      ref.__setobj__(target)

      assert_same target, ref.__getobj__
      ref << :changed

      assert_equal [:changed], target
      ref.__setobj__(nil)

      assert_nil ref.__getobj__
      ref.__setobj__(false)

      refute ref.__getobj__
    end

    def test_delegation_resolves_the_current_fiber
      ref = LocalRef.new(scope: :fiber) { [] }
      ref << :parent
      result = Fiber.new do
        before = ref.__getobj__.dup
        ref << :child
        [before, ref.__getobj__]
      end.resume

      assert_equal [[], [:child]], result
      assert_equal [:parent], ref.__getobj__
    end

    def test_replacement_is_local_to_the_current_thread
      ref = LocalRef.new("default", scope: :thread)
      ref.__setobj__("parent")
      worker = Thread.new do
        before = ref.upcase
        ref.__setobj__("child")
        [before, ref.upcase]
      end

      assert_equal %w[DEFAULT CHILD], worker.value
      assert_equal "PARENT", ref.upcase
    ensure
      worker&.kill&.join
    end

    def test_rejects_invalid_scopes
      assert_raises(ArgumentError) { LocalRef.new(scope: :invalid) }
    end

    def test_delegation_resolves_the_current_ractor
      ref = LocalRef.new { [] }
      ref << :parent
      worker = Ractor.new(ref) do |shared|
        before = shared.__getobj__.dup
        shared << :child
        [before, shared.__getobj__]
      end

      assert_equal [[], [:child]], ractor_value(worker)
      assert_equal [:parent], ref.__getobj__
    end
  end
end
