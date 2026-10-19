# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../../setup"

module Farce
  module Concurrent
    class TestFiberLocalVar < Test
      include Helpers::InternalTestHelpers
      include Helpers::ConcurrentLocalVar

      def test_values_are_isolated_between_interleaved_fibers
        variable = FiberLocalVar.new(:default)
        variable.value = :parent
        first = Fiber.new do
          initial = variable.value
          variable.value = :first
          Fiber.yield initial
          variable.value
        end
        second = Fiber.new do
          initial = variable.value
          variable.value = :second
          [initial, variable.value]
        end

        assert_equal :default, first.resume
        assert_equal %i[default second], second.resume
        assert_equal :first, first.resume
        assert_equal :parent, variable.value
      end

      def test_default_block_runs_once_per_fiber
        calls = Counter.new
        variable = FiberLocalVar.new do
          calls.increment
          Fiber.current.object_id
        end
        parent = variable.value
        child = Fiber.new { [variable.value, variable.value, Fiber.current.object_id] }.resume

        assert_equal [child.last] * 3, child
        refute_equal parent, child.last
        assert_equal parent, variable.value
        assert_equal 2, calls.value
      end

      private def local_var_class = FiberLocalVar
    end
  end
end
