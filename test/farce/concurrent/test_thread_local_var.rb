# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../../setup"

module Farce
  module Concurrent
    class TestThreadLocalVar < Test
      include Helpers::InternalTestHelpers
      include Helpers::ConcurrentLocalVar

      def test_values_are_isolated_between_threads
        variable = ThreadLocalVar.new(:default)
        variable.value = :parent
        workers = 2.times.map do |index|
          Thread.new do
            initial = variable.value
            variable.value = index
            [initial, variable.value]
          end
        end

        assert_equal [[:default, 0], [:default, 1]], workers.map(&:value)
        assert_equal :parent, variable.value
      ensure
        workers&.each { it.kill if it.alive? }
        workers&.each(&:join)
      end

      def test_fibers_in_the_same_thread_share_the_value
        variable = ThreadLocalVar.new(:default)
        variable.value = :parent
        child = Fiber.new do
          initial = variable.value
          variable.value = :child
          [initial, Fiber.new { variable.value }.resume]
        end.resume

        assert_equal %i[parent child], child
        assert_equal :child, variable.value
      end

      def test_default_block_runs_once_per_thread
        calls = Counter.new
        variable = ThreadLocalVar.new do
          calls.increment
          Thread.current.object_id
        end
        parent = variable.value
        worker = Thread.new { [variable.value, variable.value, Thread.current.object_id] }
        child = worker.value

        assert_equal [child.last] * 3, child
        refute_equal parent, child.last
        assert_equal parent, variable.value
        assert_equal 2, calls.value
      ensure
        worker&.kill if worker&.alive?
        worker&.join
      end

      private def local_var_class = ThreadLocalVar
    end
  end
end
