# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestFreezeGraph < Test
    Record = Data.define(:value)

    def test_freezes_nested_arrays_and_hash_keys_and_values_in_place
      key = [+"key"]
      value = [+"value"]
      root = { key => value }

      assert_same root, Farce.freeze_graph(root)
      [root, key, key.first, value, value.first].each { assert_predicate it, :frozen? }

      assert_same value, root[key]
      assert_raises(FrozenError) { value << :another }
      assert_raises(FrozenError) { value.first << "!" }
    end

    def test_freezes_instance_variables
      child = [+"value"]
      root = Object.new
      root.instance_variable_set(:@child, child)

      assert_same root, Farce.freeze_graph(root)
      [root, child, child.first].each { assert_predicate it, :frozen? }
    end

    def test_preserves_shared_children_and_cycles_in_place
      child = []
      root = [child, child]
      child << root
      result = Farce.freeze_graph(root)

      assert_same root, result
      assert_same child, result.first
      assert_same result.first, result.last
      assert_same result, result.first.first
      assert_predicate result, :frozen?
      assert_predicate child, :frozen?
    end

    def test_preserves_frozen_cycles_and_shared_children
      child = []
      root = [child, child]
      child << root
      child.freeze
      root.freeze

      assert_same root, Farce.freeze_graph(root)
      assert_same child, root.first
      assert_same child, root.last
      assert_same root, child.first
    end

    def test_preserves_data_identity_and_freezes_members_with_back_references
      child = []
      root = Record.new(child)
      child << root

      assert_same root, Farce.freeze_graph(root)
      assert_same child, root.value
      assert_same root, child.first
      assert_predicate child, :frozen?
    end

    def test_traverses_frozen_hashes_and_sets_without_rebuilding_them
      key = [+"key"]
      value = [+"value"]
      hash = { key => value }.freeze
      element = [+"element"]
      set = ::Set[element].freeze
      root = [hash, set].freeze

      assert_same root, Farce.freeze_graph(root)
      assert_same hash, root.first
      assert_same set, root.last
      assert_same key, hash.keys.first
      assert_same value, hash[key]
      assert_same element, set.first
      [key, key.first, value, value.first, element, element.first].each { assert_predicate it, :frozen? }
    end

    def test_traverses_already_frozen_containers
      child = [+"value"]
      root = [child].freeze
      result = Farce.freeze_graph(root)

      assert_same root, result
      assert_same child, result.first
      [result, child, child.first].each { assert_predicate it, :frozen? }
    end

    def test_accepts_immediate_values
      assert_nil Farce.freeze_graph(nil)
      [true, false, 42, :value].each do |value|
        assert_same value, Farce.freeze_graph(value)
      end
    end

    def test_skips_classes_and_modules_by_default
      [Module, Class].each do |type|
        mod = type.new
        child = [+"value"]
        mod.instance_variable_set(:@child, child)
        result = Farce.freeze_graph([mod])

        assert_predicate result, :frozen?
        assert_same mod, result.first
        [mod, child, child.first].each { refute_predicate it, :frozen? }
      end
    end

    def test_freeze_modules_traverses_instance_variables_by_default
      [Module, Class].each do |type|
        mod = type.new
        child = [+"value"]
        constant = [+"constant"]
        mod.instance_variable_set(:@child, child)
        mod.const_set(:VALUE, constant)

        assert_same mod, Farce.freeze_graph(mod, freeze_modules: true)
        [mod, child, child.first].each { assert_predicate it, :frozen? }
        [constant, constant.first].each { assert_predicate it, :frozen? }
      end
    end

    def test_traverses_modules_without_freezing_them
      [Module, Class].each do |type|
        mod = type.new
        child = [+"value"]
        mod.instance_variable_set(:@child, child)

        assert_same mod, Farce.freeze_graph(mod, traverse_modules: true)
        refute_predicate mod, :frozen?
        [child, child.first].each { assert_predicate it, :frozen? }
      end
    end

    def test_freezes_modules_without_traversing_them
      [Module, Class].each do |type|
        mod = type.new
        child = [+"value"]
        mod.instance_variable_set(:@child, child)

        assert_same mod, Farce.freeze_graph(mod, freeze_modules: true, traverse_modules: false)
        assert_predicate mod, :frozen?
        [child, child.first].each { refute_predicate it, :frozen? }
      end
    end

    def test_rejects_copy_option
      assert_raises(ArgumentError) { Farce.freeze_graph([], copy: true) }
    end
  end
end
