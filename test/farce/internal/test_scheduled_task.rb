# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../../setup"

module Farce
  module Internal
    class TestScheduledTask < Test
      class Payload
        include Farce::Unshareable::Movable
        include Farce::Unshareable::Copyable

        attr_accessor :value

        def initialize(value)
          @value = value
          super()
        end
      end

      class Completion
        attr_reader :count

        def initialize = @count = 0
        def task_finished = @count += 1
      end

      def test_unmanaged_arguments_without_completion
        task = ScheduledTask.new([:value, 42], proc { |*args| args }, :raise)

        assert_equal [:value, 42], task.to_proc.call
      end

      def test_copied_arguments_with_and_without_completion
        [false, true].each do |track_completion|
          original = Payload.new(:value)
          task = ScheduledTask.new([original], proc { |value| value }, :copy)
          completion = Completion.new if track_completion
          original.value = :changed
          result = task.to_proc(completion).call

          assert_equal :value, result.value
          refute_same original, result
          assert_equal 1, completion.count if completion
        end
      end

      def test_descriptor_copies_remain_shareable_without_retransferring_arguments
        task = ScheduledTask.new([Payload.new(:value)], proc { |value| value }, :copy)
        copies = [task.dup, task.clone, task.clone(freeze: false), task.clone(freeze: true)]

        copies.each do |copy|
          refute_same task, copy
          assert_predicate copy, :frozen?
          assert Ractor.shareable?(copy)
          assert_predicate copy, :ractor_shareable?
          assert_same task.instance_variable_get(:@args), copy.instance_variable_get(:@args)
          assert_same task.instance_variable_get(:@block), copy.instance_variable_get(:@block)
        end

        results = ([task] + copies).map { it.to_proc.call }

        results.each { assert_same results.first, it }
      end

      def test_completion_is_notified_when_a_task_raises
        %i[copy raise].each do |mode|
          args = mode == :copy ? [Payload.new(:value)] : [:value]
          task = ScheduledTask.new(args, proc { |_| raise ArgumentError, "task failed" }, mode)
          completion = Completion.new

          error = assert_raises(ArgumentError) { task.to_proc(completion).call }

          assert_equal "task failed", error.message
          assert_equal 1, completion.count
        end
      end
    end
  end
end
