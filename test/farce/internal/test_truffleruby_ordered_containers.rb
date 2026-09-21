# frozen_string_literal: true

return unless RUBY_ENGINE == "truffleruby" && TruffleRuby.native?

require_relative "../../setup"

module Farce
  module Internal
    class TestTruffleRubyOrderedContainers < Test
      def test_tree_maps_are_direct_production_classes
        map = Internal::TreeMap.new(2 => :two, 1 => :one)
        local = Internal::UnsafeTreeMap.new(2 => :two, 1 => :one)

        assert_same Internal::TreeMap, Internal::ShareableTreeMap
        assert_instance_of Internal::TreeMap, map
        assert_instance_of Internal::UnsafeTreeMap, local
        assert_equal Internal::UnsafeTreeMap, Internal::TreeMap.superclass
        assert_equal Object, Internal::UnsafeTreeMap.superclass
        refute_predicate map, :frozen?
        refute_predicate local, :frozen?
        assert_equal [1, :one], map.shift
        assert_equal [1, :one], local.shift
      end

      def test_priority_queue_is_one_class_with_storage_primitives
        queue = Internal::PriorityQueue.new(capacity: 1)

        assert_instance_of Internal::PriorityQueue, queue
        assert_equal Object, Internal::PriorityQueue.superclass
        refute_predicate queue, :frozen?
        assert_respond_to queue, :push
        assert_respond_to queue, :pop
        assert Internal::PriorityQueue.private_method_defined?(:initialize)

        assert queue.push(1, :one)
        refute queue.push(2, :full)
        assert_equal :one, queue.pop
        assert_nil queue.pop
      end
    end
  end
end
