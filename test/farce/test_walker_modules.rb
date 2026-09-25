# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestWalkerModules < Test
    def test_default_visits_owned_constants_class_variables_and_instance_variables
      [Module, Class].each do |type|
        owner = type.new
        owner.const_set(:VALUE, :constant)
        owner.class_variable_set(:@@value, :class_variable)
        owner.instance_variable_set(:@value, :instance_variable)

        assert_equal [:constant, :class_variable, :instance_variable, owner], Walker.each(owner).to_a
      end
    end

    def test_policies_can_be_disabled_independently
      owner = Module.new
      owner.const_set(:VALUE, :constant)
      owner.class_variable_set(:@@value, :class_variable)

      assert_equal [:class_variable, owner], Walker.each(owner, constants: false).to_a
      assert_equal [:constant, owner], Walker.each(owner, class_variables: false).to_a
      assert_equal [owner], Walker.each(owner, constants: false, class_variables: false).to_a
    end

    def test_inherited_values_are_excluded_by_default
      parent = Class.new
      parent.const_set(:VALUE, :constant)
      parent.class_variable_set(:@@value, :class_variable)
      child = Class.new(parent)

      assert_equal [child], Walker.each(child).to_a
      assert_equal [:constant, child], Walker.each(child, constants: :inherited).to_a
      assert_equal [:class_variable, child], Walker.each(child, class_variables: :inherited).to_a
    end

    def test_included_module_values_can_be_visited
      owner = Module.new
      owner.const_set(:VALUE, :constant)
      owner.class_variable_set(:@@value, :class_variable)
      receiver = Class.new { include owner }

      assert_equal [receiver], Walker.each(receiver).to_a
      assert_equal [:constant, :class_variable, receiver],
        Walker.each(receiver, constants: :inherited, class_variables: :inherited).to_a
    end

    def test_autoloads_are_skipped_even_when_inherited
      parent = Class.new
      parent.autoload(:Pending, "farce_walker_missing_autoload_fixture")
      child = Class.new(parent)

      assert_equal [parent], Walker.each(parent).to_a
      assert_equal [child], Walker.each(child, constants: :inherited).to_a
      assert_equal "farce_walker_missing_autoload_fixture", parent.autoload?(:Pending)
      assert_same parent, Walker.modify(parent) { |_, walker| walker.traverse }
      assert_equal "farce_walker_missing_autoload_fixture", parent.autoload?(:Pending)
    end

    def test_private_constants_are_not_visited
      owner = Module.new
      owner.const_set(:Hidden, :hidden)
      owner.private_constant(:Hidden)

      assert_equal [owner], Walker.each(owner).to_a
    end

    def test_private_constant_hides_public_ancestor_constant
      parent = Class.new
      parent.const_set(:VALUE, :parent)
      child = Class.new(parent)
      child.const_set(:VALUE, :child)
      child.private_constant(:VALUE)

      assert_equal [child], Walker.each(child, constants: :inherited).to_a
    end

    def test_read_only_walk_does_not_assign_replacements
      owner = Module.new
      owner.const_set(:VALUE, 1)
      owner.class_variable_set(:@@value, 2)
      owner.freeze
      Walker.visit(owner) { |node, walker| Integer === node ? node + 1 : walker.traverse }

      assert_equal 1, owner.const_get(:VALUE)
      assert_equal 2, owner.class_variable_get(:@@value)
    end

    def test_modify_replaces_owned_values_and_preserves_aliases
      owner = Module.new
      original = Object.new
      replacement = Object.new
      owner.const_set(:VALUE, original)
      owner.class_variable_set(:@@value, original)
      owner.instance_variable_set(:@value, original)

      capture_io do
        assert_same owner, Walker.modify(owner) { |node, walker| node.equal?(original) ? replacement : walker.traverse }
      end

      assert_same replacement, owner.const_get(:VALUE)
      assert_same replacement, owner.class_variable_get(:@@value)
      assert_same replacement, owner.instance_variable_get(:@value)
    end

    def test_unchanged_values_are_not_assigned
      owner = Module.new
      owner.const_set(:VALUE, 1)
      owner.class_variable_set(:@@value, 2)
      def owner.const_set(*) = raise("unexpected constant assignment")
      def owner.class_variable_set(*) = raise("unexpected class variable assignment")

      assert_same owner, Walker.modify(owner) { |_, walker| walker.traverse }
    end

    def test_inherited_replacements_follow_ruby_assignment_rules
      parent = Class.new
      parent.const_set(:VALUE, 1)
      parent.class_variable_set(:@@value, 2)
      child = Class.new(parent)
      sibling = Class.new(parent)
      Walker.modify(child, constants: :inherited, class_variables: :inherited) do |node, walker|
        Integer === node ? node + 10 : walker.traverse
      end

      assert_equal 1, parent.const_get(:VALUE)
      assert_equal 11, child.const_get(:VALUE, false)
      assert_equal 12, parent.class_variable_get(:@@value)
      assert_equal 12, sibling.class_variable_get(:@@value)
      assert_empty child.class_variables(false)
    end

    def test_copy_preserves_cycles_without_changing_original_slots
      [Module, Class].each do |type|
        owner = type.new
        owner.const_set(:SELF, owner)
        owner.const_set(:NUMBER, 1)
        owner.class_variable_set(:@@self, owner)
        result = nil
        capture_io do
          result = Walker.modify(owner, copy: true) { |value, walker| Integer === value ? value + 1 : walker.traverse }
        end

        refute_same owner, result
        assert_same result, result.const_get(:SELF)
        assert_same result, result.class_variable_get(:@@self)
        assert_same owner, owner.const_get(:SELF)
        assert_same owner, owner.class_variable_get(:@@self)
        assert_equal [1, owner], Walker.each(owner).to_a
      end
    end

    def test_predicates_forward_traversal_policies
      owner = Module.new
      owner.const_set(:VALUE, false)

      refute Walker.all?(owner)
      assert Walker.all?(owner, constants: false)
      assert Walker.any?(owner) { it == false }
      refute Walker.any?(owner, constants: false) { it == false }
    end

    def test_invalid_policies_are_rejected
      assert_raises(ArgumentError) { Walker.each(Module.new, constants: :unknown).to_a }
      assert_raises(ArgumentError) { Walker.modify(Module.new, class_variables: nil) { |_, walker| walker.traverse } }
    end
  end
end
