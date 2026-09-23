# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestSetReview < Test
    include Helpers::InternalTestHelpers

    TYPES = [
      Set, SortedSet, Strict::Set, Strict::SortedSet, Strict::WeakSet,
      Unshared::Set, Unshared::SortedSet, Unshared::WeakSet,
      Local::Set, Local::SortedSet, Local::WeakSet
    ].freeze

    def test_mutable_sorted_sets_can_be_the_first_tree_collection_loaded
      %w[Unshared Local].each do |namespace|
        output, error, status = ruby_subprocess(<<~RUBY, timeout: 60)
          require "farce"
          set = Farce::#{namespace}::SortedSet.new([3, 1, 2])
          raise "incorrect ordering" unless set.to_a == [1, 2, 3]
          raise "duplicate inserted" if set.add?(2)
          set.delete(1)
          set.add(4)
          raise "incorrect contents" unless set.to_a == [2, 3, 4]
          puts "ok"
        RUBY

        assert_predicate status, :success?, "#{namespace}: #{output}\n#{error}"
        assert_equal "ok\n", output
      end
    end

    def test_relation_divide_first_used_in_another_ractor
      output, error, status = ruby_subprocess(<<~RUBY, coverage: false)
        require "farce"
        set = Farce::Strict::Set[1, 2, 4]
        abort "TSort was preloaded" if defined?(::TSort)
        worker = Farce::Ractor.new(set) do |source|
          raise "expected a non-main Ractor" if Farce::Ractor.current == Farce::Ractor.main
          source.divide { |left, right| (left - right).abs <= 1 }.map { it.to_a.sort }.sort
        end
        result = worker.respond_to?(:value) ? worker.value : worker.take
        abort "incorrect groups" unless result == [[1, 2], [4]]
        puts "divided"
      RUBY

      assert_predicate status, :success?, error
      assert_equal "divided\n", output
    end

    def test_to_set_defaults_to_ruby_set
      TYPES.each do |type|
        source = type.new([1, 2])
        converted = source.to_set

        assert_instance_of ::Set, converted, type.name
        assert_equal ::Set[1, 2], converted
        assert_equal(::Set[10, 20], source.to_set { it * 10 })
        assert_same source, source.to_set(type)
        converted.add(3)

        assert_equal [1, 2], source.to_a.sort
      end
    end

    def test_no_clear_and_reinsert_mutators_are_exposed
      TYPES.each do |type|
        set = type.new([1, 2])
        %i[replace collect! map! flatten!].each { refute_respond_to set, it, type.name }
      end
    end

    def test_copy_and_selection_do_not_normalize_stored_elements_again
      normalizer = Ractor.shareable_proc { |value| value + 1 }
      TYPES.each do |type|
        original = type.new([1, 2], normalize: normalizer)
        copies = [original.dup, original.clone, original.select { true }, original.reject { false }]
        copies.each do |copy|
          assert_instance_of type, copy
          assert_equal [2, 3], copy.to_a.sort, type.name
        end
        copies.first.add(3)

        assert_equal [2, 3], original.to_a.sort, type.name
        assert_equal [2, 3, 4], copies.first.to_a.sort, type.name
      end
    end

    def test_filtering_deletes_canonical_elements_without_normalizing_again
      normalizer = Ractor.shareable_proc { |value| value + 1 }
      TYPES.each do |type|
        set = type.new([1, 2, 3], normalize: normalizer)

        assert_same(set, set.delete_if { |value| value == 2 })
        assert_equal [3, 4], set.to_a.sort, type.name
        assert_same(set, set.keep_if { |value| value == 3 })
        assert_equal [3], set.to_a, type.name
      end
    end

    def test_normalized_set_algebra_uses_stored_elements
      normalizer = Ractor.shareable_proc { |value| value + 1 }
      TYPES.each do |type|
        set = type.new([1, 2], normalize: normalizer)
        copy = set.dup

        assert_equal set, copy, type.name
        assert_equal [2, 3], (set | copy).to_a.sort, type.name
        assert_equal [2, 3], (set & copy).to_a.sort, type.name
        assert_empty set - copy, type.name
        assert_empty set ^ copy, type.name
        assert_equal [2, 3], set.classify { :all }.fetch(:all).to_a.sort, type.name
      end
    end

    def test_intersection_uses_eql_membership_for_unordered_sets
      TYPES.reject { it < Abstract::SortedSet }.each do |type|
        assert_empty type.new([1]).intersection([1.0]), type.name
      end
    end

    def test_native_top_level_sets_apply_element_transfer_modes
      return unless Internal.native_ractors?

      [Set, SortedSet].each do |type|
        original = [1]
        set = type.new([original])
        original << 2

        assert_equal :copy, set.mode
        assert_equal [[1]], set.to_a
        assert_includes set, [1]
        refute_includes set, [1, 2]
        refute_same original, set.first

        local = type.new([original], mode: :local)

        assert_same original, local.first

        shareable_copy = type.new([original], mode: :shareable_copy)

        assert_predicate shareable_copy.first, :frozen?
        refute_predicate original, :frozen?

        made_shareable = type.new([original], mode: :make_shareable)

        assert_predicate original, :frozen?
        assert_same original, made_shareable.first
        assert_raises(Ractor::IsolationError) { type.new([[2]], mode: :raise) } if Internal.native_ractors?
      end
    end

    def test_mode_overrides_and_duplicate_moves_leave_existing_members_alone
      [Set, SortedSet].each do |type|
        set = type.new(mode: :copy)
        original = [1]
        set.add(original, mode: :local)

        assert_same original, set.first
        duplicate = [1]

        assert_nil set.add?(duplicate, mode: :move)
        assert_equal [1], duplicate
        assert_equal 1, set.size
      end
    end

    def test_membership_and_copying_do_not_claim_moved_elements
      return unless Internal.native_ractors?

      [Set, SortedSet].each do |type|
        set = type.new([[1]], mode: :move)
        duplicate = set.dup

        assert_includes set, [1]
        assert_includes duplicate, [1]
        assert_equal [[1]], ractor_value(Ractor.new(duplicate, &:to_a))
      end
    end

    def test_mode_membership_distinguishes_eql_from_double_equals
      [Set].each do |type|
        set = type.new([[1]])

        assert_includes set, [1]
        refute_includes set, [1.0]
        assert_same set, set.add?([1.0])
        assert_equal 2, set.size
      end
    end

    def test_sets_keep_nil_and_false_as_distinct_members
      TYPES.reject { it < Abstract::SortedSet }.each do |type|
        set = type.new

        assert_same set, set.add?(nil)
        assert_same set, set.add?(false)
        assert_nil set.add?(nil)
        assert_nil set.add?(false)
        assert_equal 2, set.size
        assert_same set, set.delete?(nil)
        assert_includes set, false
        assert_same set, set.delete?(false)
        assert_empty set
      end
    end

    def test_mode_set_algebra_and_relations_use_membership_keys
      [Set, SortedSet].each do |type|
        left = type.new([[1], [2]])
        same = type.new([[2], [1]])
        larger = type.new([[1], [2], [3]])

        assert_equal left, same
        assert left.eql?(same)
        assert_equal left.hash, same.hash
        assert left.subset?(larger)
        assert left.proper_subset?(larger)
        assert larger.superset?(left)
        assert larger.proper_superset?(left)
        assert left.intersect?(same)
        refute left.disjoint?(same)
        assert_equal [[2]], (left - [[1]]).to_a
        assert_equal [[1], [2]], left.flatten.to_a.sort
        assert_equal [[[1]], [[2]]], left.divide { |a, b| a == b }.map(&:to_a).sort
      end
    end

    def test_native_mode_filters_remove_stored_members_after_payload_mutation
      return unless Internal.native_ractors?

      [Set, SortedSet].each do |type|
        value = [1]
        set = type.new([value], mode: :local)
        original_hash = set.hash
        value << 2

        assert_equal original_hash, set.hash
        assert_includes set, [1]
        refute_includes set, [1, 2]
        assert_same(set, set.reject! { |element| element == [1, 2] })
        assert_empty set
      end
    end

    def test_cross_variant_equality_has_consistent_hashes
      sets = TYPES.map { it.new([1, 2]) }
      sets.product(sets).each do |left, right|
        if left.is_a?(Abstract::SortedSet) == right.is_a?(Abstract::SortedSet)
          assert left.eql?(right), "#{left.class} and #{right.class}"
          assert_equal left.hash, right.hash, "#{left.class} and #{right.class}"
        else
          refute_equal left, right
          refute left.eql?(right), "#{left.class} and #{right.class}"
        end
      end
    end

    def test_equality_does_not_normalize_another_sets_stored_members
      normalizer = Ractor.shareable_proc { |value| value + 1 }
      TYPES.each do |type|
        normalized = type.new([1], normalize: normalizer)
        plain = type.new([2])

        assert_operator normalized, :eql?, plain, type.name
        assert_operator plain, :eql?, normalized, type.name
        assert_equal normalized.hash, plain.hash, type.name
      end
    end

    def test_unshared_equality_preserves_nested_object_identity
      child = Object.new
      element = [child]
      left = Unshared::Set.new([element])
      right = Unshared::Set.new([element])

      assert_equal left, right
      assert_equal left.hash, right.hash
      refute_predicate element, :frozen?
      refute_predicate child, :frozen?
    end

    def test_independent_local_mode_sets_agree_on_identity_membership
      original = Object.new
      left = Set.new([original], mode: :local)
      right = Set.new([original], mode: :local)

      assert_equal left, right
      assert_equal left.hash, right.hash
      assert_equal 1, (left | right).size
      assert_empty left - right
      assert left.subset?(right)
    end

    def test_identity_membership_survives_making_a_local_element_shareable
      original = Object.new
      local = Set.new([original], mode: :local)
      shared = Set.new([original], mode: :make_shareable)

      assert_includes local, original
      assert_includes shared, original
      assert_equal local, shared
      assert_equal local.hash, shared.hash
      plain = Unshared::Set.new([original])

      assert_equal local, plain
      assert_equal plain, local
      assert_equal local.hash, plain.hash
    end

    def test_mode_local_supports_default_identity_elements
      original = Object.new
      set = Set.new([original], mode: :local)

      assert_same original, set.first
      assert_includes set, original
      refute_includes set, Object.new
      assert_nil set.add?(original)
      assert_same set, set.delete?(original)
      assert_empty set
    end

    def test_divide_returns_a_strong_farce_set_of_same_kind_subgroups
      TYPES.each do |type|
        source = type.new([1, 2, 3, 4])
        result = source.divide(&:even?)

        assert_kind_of Abstract::Set, result, type.name
        refute_predicate result, :weak?
        result.each { assert_instance_of type, it }

        assert_equal [[1, 3], [2, 4]], result.map { it.to_a.sort }.sort
      end
    end

    def test_atomic_conditional_insert_and_delete
      [Set, SortedSet, Strict::Set, Strict::SortedSet, Strict::WeakSet,
       Unshared::Set, Unshared::SortedSet, Unshared::WeakSet].each do |type|
        set = type.new
        ready = Thread::Queue.new
        start = Thread::Queue.new
        workers = Array.new(8) do
          Thread.new do
            ready << true
            start.pop
            set.add?(:entry)
          end
        end
        8.times { ready.pop }
        8.times { start << true }

        assert_equal 1, workers.count { |worker| worker.value.equal?(set) }, type.name
        workers = Array.new(8) { Thread.new { set.delete?(:entry) } }

        assert_equal 1, workers.count { |worker| worker.value.equal?(set) }, type.name
        assert_empty set
      end
    end

    def test_shareable_sets_support_other_ractors_and_independent_frozen_copies
      [Set, SortedSet, Strict::Set, Strict::SortedSet, Strict::WeakSet].each do |type|
        set = type.new([1])
        worker = Ractor.new(set) { |shared| shared.add(2).to_a.sort }

        assert_equal [1, 2], ractor_value(worker), type.name
        assert_equal [1, 2], set.to_a.sort, type.name
        set.freeze
        mutable = set.dup
        frozen = set.clone

        assert Ractor.shareable?(mutable)
        assert Ractor.shareable?(frozen)
        refute_predicate mutable, :frozen?
        assert_predicate frozen, :frozen?
        mutable.add(3)

        assert_equal [1, 2], frozen.to_a.sort, type.name
        assert_equal [1, 2, 3], mutable.to_a.sort, type.name
      end
    end

    def test_frozen_sets_reject_no_op_mutations
      TYPES.reject { |type| type < Unshareable }.each do |type|
        set = type.new.freeze
        assert_raises(FrozenError, type.name) { set.merge([]) }
        assert_raises(FrozenError, type.name) { set.subtract([]) }
        assert_raises(FrozenError, type.name) { set.delete_if { false } }
        assert_raises(FrozenError, type.name) { set.keep_if { true } }
      end
    end

    def test_local_copies_preserve_scope_and_independent_contents
      [Local::Set, Local::SortedSet, Local::WeakSet].each do |type|
        set = type.new([1], scope: :thread)
        set.add(2)
        copy = set.dup
        copy.add(3)

        assert_equal [1, 2], set.to_a.sort, type.name
        assert_equal [1, 2, 3], copy.to_a.sort, type.name
        assert_equal :thread, copy.scope
        assert_equal [[1], [1]], Thread.new { [set.to_a, copy.to_a] }.value, type.name
      end
    end
  end
end
