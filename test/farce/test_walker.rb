# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestWalker < Test
    class Box
      attr_accessor :value

      def initialize(value) = @value = value
    end

    class CustomBox < Box
    end

    class CopyableBox < Box
      def snapshot = self.class.new(value)
    end

    class ExtendedBox < Box
    end

    Record = Data.define(:value)

    ValidatedRecord = Data.define(:value) do
      def initialize(value:)
        raise ArgumentError, "array expected" unless value.is_a?(Array)
        super
      end
    end

    def test_each_visits_children_before_parents_once_by_identity
      child = [1]
      root = [child, child, [1]]
      visited = Walker.each(root).to_a

      assert_equal [1, child, root.last, root], visited
      assert_same child, visited[1]
      assert_same root.last, visited[2]
      assert_same root, Walker.each(root) { :ignored }
    end

    def test_each_visits_hash_keys_and_values
      key = [+"key"]
      value = [+"value"]
      root = { key => value }

      assert_equal [key.first, key, value.first, value, root], Walker.each(root).to_a
    end

    def test_visit_only_descends_when_requested
      root = [[1]]
      visited = []
      result = Walker.visit(root) do |object, walker|
        visited << object

        assert_same object, walker.current_object
        :done
      end

      assert_equal [root], visited
      assert_equal :done, result
    end

    def test_visit_restores_current_object_after_a_child
      root = [[1]]
      Walker.visit(root) do |object, walker|
        walker.traverse

        assert_same object, walker.current_object
        object
      end
    end

    def test_skip_returns_a_replacement_without_visiting_children
      root = [[1], 2]
      visited = []
      result = Walker.modify(root) do |object, walker|
        visited << object
        walker.skip(:skipped) if object.equal?(root.first)
        walker.traverse
      end

      assert_equal [:skipped, 2], result
      refute_includes visited, 1
    end

    def test_return_stops_the_whole_walk
      visited = []
      result = Walker.visit([1, 2]) do |object, walker|
        visited << object
        walker.return(:found) if object == 1
        walker.traverse
      end

      assert_equal :found, result
      refute_includes visited, 2
    end

    def test_any_and_all_short_circuit
      visited = []

      assert(Walker.any?([1, 2]) do |value|
        visited << value
        value == 1
      end)
      assert_equal [1], visited
      visited.clear

      refute(Walker.all?([1, 2]) do |value|
        visited << value
        value != 1
      end)
      assert_equal [1], visited
    end

    def test_cycles_are_visited_once
      root = []
      root << root

      assert_equal 1, Walker.each(root).count
      assert_same root, Walker.each(root).first
    end

    def test_modify_changes_arrays_and_instance_variables_in_place
      box = Box.new([1, 2])
      result = increment(box)

      assert_same box, result
      assert_equal [2, 3], result.value
    end

    def test_modify_preserves_self_references
      root = [1]
      root << root
      result = increment(root)

      assert_same root, result
      assert_equal 2, result.first
      assert_same result, result.last
    end

    def test_copy_preserves_shared_children_and_mutual_cycles
      left = []
      right = [left, 1]
      left.push(right, right)
      result = increment(left, copy: true)

      refute_same left, result
      refute_same right, result.first
      assert_same result.first, result.last
      assert_same result, result.first.first
      assert_equal 2, result.first.last
      assert_same left, right.first
      assert_equal 1, right.last
    end

    def test_copy_preserves_instance_variable_cycles
      box = Box.new(nil)
      box.value = box
      box.instance_variable_set(:@number, 1)
      result = increment(box, copy: true)

      refute_same box, result
      assert_same result, result.value
      assert_same box, box.value
    end

    def test_hash_keys_and_values_are_replaced_without_losing_colliding_old_keys
      input = { 1 => 10, 2 => 20 }

      assert_same input, increment(input)
      assert_equal({ 2 => 11, 3 => 21 }, input)
    end

    def test_copy_preserves_hash_cycles_and_defaults
      input = Hash.new(:missing)
      input[:self] = input
      input[:number] = 1
      result = increment(input, copy: true)

      refute_same input, result
      assert_same result, result[:self]
      assert_equal :missing, result[:unknown]
      assert_same input, input[:self]
    end

    def test_sets_can_replace_elements_that_overlap_old_elements
      [::Set, Set].each do |klass|
        input = klass[1, 2]

        assert_same input, increment(input)
        assert_equal klass[2, 3], input
      end
    end

    def test_copy_preserves_the_original_set
      input = Set[1, 2]
      result = increment(input, copy: true)

      refute_same input, result
      assert_equal Set[1, 2], input
      assert_equal Set[2, 3], result
    end

    def test_data_members_are_replaced
      input = Record.new(1)
      result = increment(input)

      assert_equal 1, input.value
      assert_equal 2, result.value
      assert_predicate result, :frozen?
    end

    def test_data_cycles_use_the_initialized_replacement
      children = []
      original = Record.new(children)
      children.push(original, 1)
      result = increment(original, copy: true)

      refute_same original, result
      refute_same children, result.value
      assert_same result, result.value.first
      assert_same original, children.first
      assert_predicate result, :frozen?
    end

    def test_data_custom_initializers_receive_transformed_members
      original = ValidatedRecord.new(value: [1])
      result = increment(original, copy: true)

      assert_instance_of ValidatedRecord, result
      assert_equal [2], result.value
      assert_equal [1], original.value
      assert_predicate result, :frozen?
      assert_raises(ArgumentError) do
        Walker.modify(original) { |object, walker| Array === object ? :invalid : walker.traverse }
      end
    end

    def test_data_custom_initializers_support_cycles
      children = []
      original = ValidatedRecord.new(value: children)
      children.push(original, 1)
      result = increment(original, copy: true)

      assert_same result, result.value.first
      assert_same original, children.first
      assert_predicate result, :frozen?
    end

    def test_read_only_data_traversal_uses_the_original
      original = Record.new([1])

      assert_equal [1, original.value, original], Walker.each(original).to_a
      assert_same original, Walker.each(original).to_a.last
    end

    def test_unfinished_data_hash_keys_are_rejected
      members = {}
      original = Record.new(members)
      members[original] = :value
      members[:number] = 1
      members.rehash

      error = assert_raises(ArgumentError) { increment(original, copy: true) }

      assert_match(/unfinished Data/, error.message)
      assert_equal :value, members[original]
    end

    def test_unfinished_data_nested_in_a_hash_key_is_rejected
      members = {}
      original = Record.new(members)
      members[[original]] = :value
      members[:number] = 1
      members.rehash

      assert_raises(ArgumentError) { increment(original, copy: true) }
    end

    def test_unfinished_data_set_elements_are_rejected
      members = ::Set.new
      original = Record.new(members)
      members.add(original)
      members.add(1)

      assert_raises(ArgumentError) { increment(original, copy: true) }
    end

    def test_identity_hashes_can_use_unfinished_data_as_keys
      members = {}.compare_by_identity
      original = Record.new(members)
      members[original] = :value
      result = increment(original, copy: true)

      assert_predicate result.value, :compare_by_identity?
      assert_same result, result.value.keys.first
      assert_equal :value, result.value[result]
      assert_equal :value, members[original]
    end

    def test_identity_sets_can_contain_unfinished_data
      members = ::Set.new.compare_by_identity
      original = Record.new(members)
      members.add(original)
      result = increment(original, copy: true)

      assert_same result, result.value.first
      assert_includes result.value, result
      assert_includes members, original
    end

    def test_internal_atoms_retain_their_wrapper
      atom = Internal::Atom.new(1)

      assert_same atom, increment(atom)
      assert_equal 2, atom.value
    end

    def test_read_only_atom_traversal_does_not_write
      atom = Internal::Atom.new(1).freeze

      assert_equal [1, atom], Walker.each(atom).to_a
    end

    def test_public_atoms_expose_values_without_walking_storage
      atom = Atom.new(1)

      assert_equal [1, atom], Walker.each(atom).to_a
      assert_same atom, increment(atom)
      assert_equal 2, atom.value
    end

    def test_vectors_expose_elements_without_walking_storage
      vector = Vector[1, 2]

      assert_equal [1, 2, vector], Walker.each(vector).to_a
      assert_same vector, increment(vector)
      assert_equal [2, 3], vector.to_a
    end

    def test_internal_vectors_use_their_snapshot_api
      vector = Internal::Vector.new([1, 2])

      assert_equal [1, 2, vector], Walker.each(vector).to_a
      assert_same vector, increment(vector)
      assert_equal [2, 3], vector.snapshot
    end

    def test_unchanged_children_are_not_assigned_again
      object = Box.new(1)
      def object.instance_variable_set(*) = raise("unexpected write")

      assert_same object, Walker.modify(object) { |_, walker| walker.traverse }
      assert_equal 1, object.value
    end

    def test_maps_transform_keys_and_values
      map = Unshared::Map.new({ 1 => 10, 2 => 20 })
      visited = Walker.each(map).to_a

      assert_same map, visited.last
      assert_equal [1, 2, 10, 20], visited[0...-1].sort
      assert_same map, increment(map)
      assert_equal({ 2 => 11, 3 => 21 }, map.to_h)
    end

    def test_leases_return_the_resource_after_traversal
      lease = Unshared::Lease.new { [1] }

      assert_same lease, increment(lease)
      assert_predicate lease, :available?
      assert_equal [2], lease.checkout(&:dup)
    end

    def test_leases_return_the_resource_when_the_callback_raises
      lease = Unshared::Lease.new { [1] }

      assert_raises(RuntimeError) do
        Walker.visit(lease) { |object, walker| object == 1 ? raise("failed") : walker.traverse }
      end
      assert_predicate lease, :available?
    end

    def test_lease_maps_transform_keys_and_resources_and_release_ownership
      map = Unshared::LeaseMap.new { { 1 => [10], 2 => [20] } }

      assert_same map, increment(map)
      assert_equal [2, 3], map.keys.sort
      assert_equal [11], map.checkout(2, &:dup)
      assert_equal [21], map.checkout(3, &:dup)
      assert map.available?(2)
      assert map.available?(3)
    end

    def test_compare_and_set_retries_read_the_current_map_value
      klass = Class.new(Unshared::Map) do
        def compare_and_set(key, expected, replacement, **)
          unless @interfered
            @interfered = true
            self[key] = 10
          end
          super
        end
      end
      map = klass.new({ count: 1 })

      assert_same map, increment(map)
      assert_equal 11, map[:count]
    end

    def test_proc_receivers_can_be_replaced
      receiver = [1]
      callable = receiver.instance_eval { proc { self } }
      result = increment(callable, copy: true)

      refute_same callable, result
      assert_equal [2], result.call
      assert_equal [1], callable.call
    end

    def test_basic_objects_can_be_traversed
      object = BasicObject.new
      object.instance_eval { @value = 1 }
      result = increment(object)

      assert_same object, result
      assert_equal(2, result.instance_eval { @value })
    end

    def test_freeze_policy
      frozen_input = [1].freeze
      preserved = increment(frozen_input)
      thawed = increment(frozen_input, freeze: false)
      frozen_output = increment([1], freeze: true)

      assert_equal [2], preserved
      assert_predicate preserved, :frozen?
      refute_predicate thawed, :frozen?
      assert_predicate frozen_output, :frozen?
      assert_equal [1], frozen_input
    end

    def test_copy_can_use_a_named_method
      original = CopyableBox.new(1)
      result = Walker.modify(original, copy: :snapshot) do |object, walker|
        Integer === object ? object + 1 : walker.traverse
      end

      refute_same original, result
      assert_equal 1, original.value
      assert_equal 2, result.value
    end

    def test_clone_preserves_singleton_methods
      original = Box.new(1)
      def original.label = :kept
      result = increment(original, copy: :clone)

      refute_same original, result
      assert_equal :kept, result.label
      assert_equal 2, result.value
    end

    def test_definitions_apply_after_a_class_was_already_visited
      original = CustomBox.new(1)
      Walker.each(original).to_a
      Walker.define(CustomBox) do |object, walker|
        walker.visit(:custom)
        object
      end

      assert_equal [:custom, original], Walker.each(original).to_a
    end

    def test_required_blocks_and_copy_validation
      assert_raises(LocalJumpError) { Walker.visit([]) }
      assert_raises(LocalJumpError) { Walker.modify([]) }
      assert_raises(ArgumentError) { Walker.modify([], copy: 123) { |object| object } }
    end

    def test_custom_definitions_can_call_super
      Walker.define(ExtendedBox) do |object, walker|
        walker.visit(:extra)
        super(object, walker)
      end
      object = ExtendedBox.new(1)

      assert_equal [:extra, 1, object], Walker.each(object).to_a
      assert_same object, increment(object)
      assert_equal 2, object.value
    end

    private

    def increment(object, **)
      Walker.modify(object, **) { |value, walker| Integer === value ? value + 1 : walker.traverse }
    end
  end
end
