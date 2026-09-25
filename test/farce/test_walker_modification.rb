# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestWalkerModification < Test
    class CustomBox
      attr_accessor :value

      def initialize(value) = @value = value
    end
    Record = Data.define(:value)

    def test_unchanged_graph_retains_all_identities
      [false, true, :clone].each do |copy|
        leaf = +"leaf"
        child = [leaf].freeze
        root = [child]
        result = Walker.modify(root, copy:) { |_, walker| walker.traverse }

        assert_same root, result
        assert_same child, result.first
        assert_same leaf, result.first.first
        refute_predicate leaf, :frozen?
      end
    end

    def test_copy_only_rebuilds_the_changed_branch
      stable = [+"stable"]
      changed = [1]
      root = [stable, changed]
      result = increment(root, copy: true)

      refute_same root, result
      assert_same stable, result.first
      refute_same changed, result.last
      assert_equal [2], result.last
      assert_equal [1], changed
    end

    def test_unchanged_cycles_are_shared
      [false, true].each do |copy|
        root = []
        child = [root]
        root.push(child, child)
        root.freeze
        result = Walker.modify(root, copy:) { |_, walker| walker.traverse }

        assert_same root, result
        assert_same child, result.first
        assert_same result, result.first.first
      end
    end

    def test_changed_mutual_cycle_uses_only_replacements
      first = []
      second = [first, 1]
      first << second
      result = increment(first, copy: true)

      refute_same first, result
      refute_same second, result.first
      assert_same result, result.first.first
      assert_equal 2, result.first.last
      assert_same first, second.first
      assert_equal 1, second.last
    end

    def test_cycles_are_resolved_when_change_is_found_after_the_back_reference
      root = []
      root.push(root, 1)
      result = increment(root, copy: true)

      assert_same result, result.first
      assert_equal 2, result.last
      assert_equal 1, root.last
    end

    def test_in_place_descendant_changes_rehash_keys_and_set_elements
      [false, true].each do |copy|
        key = [1]
        hash = { key => :value }
        result = increment(hash, copy:)

        assert_equal :value, result[[2]]
        assert_equal 1, result.size
        assert_equal(copy ? [1] : [2], key)

        element = [1]
        set = ::Set[element]
        result = increment(set, copy:)

        assert_includes result, [2]
        assert_equal 1, result.size
      end
    end

    def test_data_is_reused_when_members_do_not_change
      child = [+"value"]
      root = Record.new(child)

      assert_same root, Walker.modify(root, copy: true) { |_, walker| walker.traverse }
      assert_same child, root.value
    end

    def test_freeze_true_copies_mutable_nodes_before_freezing
      child = []
      root = [child]
      result = Walker.modify(root, copy: true, freeze: true) { |_, walker| walker.traverse }

      refute_same root, result
      refute_same child, result.first
      assert_predicate result, :frozen?
      assert_predicate result.first, :frozen?
      refute_predicate root, :frozen?
      refute_predicate child, :frozen?
    end

    def test_explicit_freezing_of_cyclic_results_is_deferred
      root = []
      root.push(root, 1)
      result = Walker.modify(root, copy: true) do |value, walker|
        next value + 1 if Integer === value
        walker.traverse
        walker.freeze_result
      end

      assert_same result, result.first
      assert_predicate result, :frozen?
      refute_predicate root, :frozen?
      assert_equal 2, result.last
    end

    def test_finalizers_run_once_after_cycles_are_connected
      root = []
      root.push(root, 1)
      calls = []
      result = Walker.modify(root, copy: true) do |value, walker|
        next value + 1 if Integer === value
        walker.traverse
        walker.finalize do |settled, cyclic|
          calls << cyclic

          assert_same settled, settled.first
          settled
        end
      end

      assert_equal [true], calls
      assert_same result, result.first
    end

    def test_acyclic_finalizer_can_return_a_canonical_value
      canonical = [].freeze
      root = [[]]
      result = Walker.modify(root, copy: true) do |value, walker|
        traversed = walker.traverse
        value.empty? ? walker.finalize { canonical } : traversed
      end

      assert_same canonical, result.first
      refute_same root, result
      refute_same canonical, root.first
    end

    def test_nonconvergent_cycle_raises
      root = []
      root << root

      assert_raises(ArgumentError) do
        Walker.modify(root, copy: true) { |_, walker| walker.traverse.dup }
      end
    end

    def test_skipping_an_immediate_value_does_not_skip_parent_finalization
      root = [1]
      result = Walker.modify(root, copy: true, freeze: true) do |value, walker|
        walker.skip if Integer === value
        walker.traverse
      end

      assert_predicate result, :frozen?
      refute_predicate root, :frozen?
    end

    def test_current_object_survives_nested_scalar_traversal
      Walker.modify([1]) do |value, walker|
        walker.traverse

        assert_same value, walker.current_object
        value
      end
    end

    def test_explicit_traversal_target_is_transformed_without_copying_the_root
      root = Object.new
      other = [1]
      result = Walker.modify(root, copy: true) do |value, walker|
        if value.equal?(root)
          walker.traverse(other)
        else
          value + 1
        end
      end

      assert_equal [2], result
      assert_equal [1], other
      refute_same other, result
    end

    def test_custom_definitions_record_assignments_for_reading_and_modifying
      Walker.define(CustomBox) do |object, walker|
        walker.update(object, [object.value]) do |target, values|
          target.value = values.first
          target
        end
      end
      original = CustomBox.new(1)

      assert_equal [1, original], Walker.each(original).to_a
      assert_same original, Walker.modify(original, copy: true) { |_, walker| walker.traverse }
      result = increment(original, copy: true)

      refute_same original, result
      assert_equal 2, result.value
      assert_equal 1, original.value
    end

    def test_keys_that_refer_to_their_own_hash_remain_retrievable
      [false, true].each do |copy|
        root = {}
        key = [root, 1]
        root[key] = :value
        root.rehash
        result = increment(root, copy:)
        transformed_key = result.keys.first

        assert_equal :value, result[transformed_key]
        assert_same result, transformed_key.first
        assert_equal 2, transformed_key.last
      end
    end

    def test_generated_cycles_preserve_every_edge
      10.times do |seed|
        random = Random.new(seed)
        nodes = Array.new(8) { [] }
        nodes.each_with_index { |node, index| node.push(index, nodes.sample(random:), nodes.sample(random:)) }
        originals = nodes.map(&:dup)
        nodes.each(&:freeze) if seed.even?
        result = increment(nodes, copy: true)
        nodes.each_with_index do |node, index|
          assert_equal index + 1, result[index].first
          assert_equal index, node.first
          [1, 2].each do |edge|
            target = nodes.index { it.equal?(originals[index][edge]) }

            assert_same result[target], result[index][edge]
          end
        end
      end
    end

    def test_data_can_be_rebuilt_after_a_cyclic_callback_changes_its_result
      child = []
      root = Record.new(child)
      child.push(root, 1)
      canonical = [].freeze
      result = Walker.modify(root, copy: true) do |value, walker|
        next value + 1 if Integer === value
        traversed = walker.traverse
        Array === value && traversed.last == 2 ? canonical : traversed
      end

      assert_same canonical, result.value
      assert_same child, root.value
      assert_equal 1, child.last
    end

    def test_data_can_have_a_member_named_members
      record = Data.define(:members) # rubocop:disable Lint/DataDefineOverride
      original = record.new(1)

      assert_equal [1, original], Walker.each(original).to_a
      assert_equal 2, increment(original, copy: true).members
    end

    def test_cyclic_finalizer_cannot_replace_the_result
      root = []
      root << root

      assert_raises(ArgumentError) do
        Walker.modify(root) do |_, walker|
          walker.traverse
          walker.finalize { [] }
        end
      end
    end

    def test_frozen_hash_does_not_copy_when_only_value_contents_change_in_place
      child = [1]
      root = { value: child }.freeze
      result = increment(root)

      assert_same root, result
      assert_same child, result[:value]
      assert_equal [2], child
    end

    def test_farce_map_rebuilds_keys_changed_in_place
      key = [1]
      root = Unshared::Map.new({ key => :value })

      assert_same root, increment(root)
      assert_equal :value, root[[2]]
      assert_equal 1, root.size
    end

    def test_deferred_lease_assignment_failure_returns_the_original_resource
      resource = []
      lease = Unshared::Lease.new { resource }
      resource << lease

      assert_raises(ArgumentError) do
        Walker.modify(lease) do |value, walker|
          result = walker.traverse
          Array === value ? nil : result
        end
      end
      assert_predicate lease, :available?
      assert_same resource, lease.checkout(&:itself)
    end

    def test_skip_after_cyclic_traversal_retains_its_explicit_result
      root = []
      root.push(root, 1)
      result = Walker.modify(root, copy: true, freeze: true) do |value, walker|
        next value + 1 if Integer === value
        walker.traverse
        walker.skip(value)
      end

      assert_same root, result
      assert_same root, root.first
      assert_equal 1, root.last
      refute_predicate root, :frozen?
    end

    private

    def increment(object, **)
      Walker.modify(object, **) { |value, walker| Integer === value ? value + 1 : walker.traverse }
    end
  end
end
