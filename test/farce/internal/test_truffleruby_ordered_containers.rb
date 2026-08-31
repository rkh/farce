# frozen_string_literal: true

return unless RUBY_ENGINE == "truffleruby" && TruffleRuby.native?

require_relative "../../setup"

module Farce
  class TestTruffleRubyOrderedContainers < Test
    def test_tree_maps_are_direct_production_classes
      map = Internal::TreeMap.new(2 => :two, 1 => :one)
      local = Internal::LocalTreeMap.new(2 => :two, 1 => :one)

      assert_same Internal::TreeMap, Internal::ShareableTreeMap
      assert_instance_of Internal::TreeMap, map
      assert_instance_of Internal::LocalTreeMap, local
      assert_equal Internal::LocalTreeMap, Internal::TreeMap.superclass
      assert_equal Object, Internal::LocalTreeMap.superclass
      assert_predicate map, :frozen?
      refute_predicate local, :frozen?
      assert_equal [1, :one], map.shift
      assert_equal [1, :one], local.shift
    end

    def test_priority_queue_is_one_class_with_storage_primitives
      queue = Internal::PriorityQueue.new(capacity: 1)

      assert_instance_of Internal::PriorityQueue, queue
      assert_equal Object, Internal::PriorityQueue.superclass
      assert_predicate queue, :frozen?
      refute_respond_to queue, :try_push
      refute_respond_to queue, :try_pop
      assert Internal::PriorityQueue.private_method_defined?(:try_push)
      assert Internal::PriorityQueue.private_method_defined?(:try_pop)
      assert Internal::PriorityQueue.private_method_defined?(:initialize_storage)

      assert queue.send(:try_push, 1, :one)
      refute queue.send(:try_push, 2, :full)
      assert_equal :one, queue.send(:try_pop)
      assert_nil queue.send(:try_pop)
    end
  end
end
