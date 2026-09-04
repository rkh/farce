# frozen_string_literal: true

require_relative "../../setup"

module Farce
  module Abstract
    class TestValue < Test
      class Node
        include Value

        attr_accessor :value
        attr_reader :name

        def initialize(name, value = nil)
          @name = name
          @value = value
        end
      end

      class EqualNode < Node
        def hash = 0
        def eql?(other) = other.is_a?(EqualNode)
      end

      def test_returns_a_direct_value
        terminal = Object.new
        wrapper = Node.new(:wrapper, terminal)

        assert_kind_of Value, wrapper
        assert_same terminal, wrapper.unwrap
      end

      def test_preserves_false_and_nil
        assert_same false, Node.new(:false_value, false).unwrap
        assert_nil Node.new(:nil).unwrap
      end

      def test_unwraps_nested_values
        terminal = Object.new
        inner = Node.new(:inner, terminal)
        middle = Node.new(:middle, inner)
        outer = Node.new(:outer, middle)

        assert_same terminal, outer.unwrap
      end

      def test_does_not_call_the_cycle_block_for_an_acyclic_chain
        result = Node.new(:outer, Node.new(:inner, 42)).unwrap do
          flunk "cycle handler called for an acyclic chain"
        end

        assert_equal 42, result
      end

      def test_self_reference_uses_the_default
        node = Node.new(:self)
        node.value = node
        fallback = Object.new

        assert_nil node.unwrap
        assert_same fallback, node.unwrap(fallback)
      end

      def test_self_reference_yields_the_repeated_value
        node = Node.new(:self)
        node.value = node
        yielded = nil
        result = node.unwrap do |repeated|
          yielded = repeated
          :cycle
        end

        assert_equal :cycle, result
        assert_same node, yielded
      end

      def test_cycle_below_the_root_yields_the_start_of_the_cycle
        first = Node.new(:first)
        second = Node.new(:second)
        root = Node.new(:root, first)
        first.value = second
        second.value = first

        repeated = root.unwrap { it }

        assert_same first, repeated
      end

      def test_cycle_that_returns_to_the_root_yields_the_root
        root = Node.new(:root)
        middle = Node.new(:middle)
        inner = Node.new(:inner)
        root.value = middle
        middle.value = inner
        inner.value = root

        repeated = root.unwrap { it }

        assert_same root, repeated
      end

      def test_block_takes_precedence_over_the_default
        node = Node.new(:self)
        node.value = node

        result = node.unwrap(:default) { :block }

        assert_equal :block, result
      end

      def test_distinct_equal_wrappers_are_not_mistaken_for_a_cycle
        terminal = Object.new
        second = EqualNode.new(:second, terminal)
        first = EqualNode.new(:first, second)

        assert first.eql?(second)
        refute_same first, second
        assert_same terminal, first.unwrap
      end

      def test_equal_wrappers_still_report_an_actual_identity_cycle
        first = EqualNode.new(:first)
        second = EqualNode.new(:second, first)
        root = EqualNode.new(:root, first)
        first.value = second

        repeated = root.unwrap { it }

        assert_same first, repeated
      end
    end
  end
end
