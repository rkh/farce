# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "psych"

module Farce
  class TestSets < Test
    include Helpers::InternalTestHelpers

    STRONG_TYPES = [Set, SortedSet, Strict::Set, Strict::SortedSet, Unshared::Set, Unshared::SortedSet,
                    Local::Set, Local::SortedSet].freeze
    WEAK_TYPES = [Strict::WeakSet, Unshared::WeakSet, Local::WeakSet].freeze
    TYPES = (STRONG_TYPES + WEAK_TYPES).freeze

    MutableOrderedKey = Struct.new(:rank) do
      def <=>(other) = rank <=> other.rank
    end

    def test_public_hierarchy_and_properties
      refute Farce.const_defined?(:WeakSet, false)
      refute Farce.const_defined?(:WeakSortedSet, false)
      assert_equal Abstract::Set, Set.superclass
      assert_equal Abstract::SortedSet, SortedSet.superclass

      TYPES.each do |type|
        set = type.new

        assert_kind_of Abstract::Set, set, type.name
        assert_equal set.is_a?(Abstract::WeakSet), set.weak?, type.name
        assert_equal set.is_a?(Unshareable), !set.ractor_shareable?, type.name
        assert_equal set.is_a?(Unshareable), !Ractor.shareable?(set), type.name
      end
      WEAK_TYPES.each { assert_kind_of Abstract::WeakSet, it.new }
    end

    def test_construction_and_basic_mutation
      enumerable = Object.new
      enumerable.define_singleton_method(:each) { |&block| [1, 2, 2].each(&block) }

      TYPES.each do |type|
        set = type.new(enumerable) { it * 2 }

        assert_equal [2, 4], set.to_a.sort, type.name
        assert_same set, set.add(3)
        assert_nil set.add?(3)
        assert_same set, set.add?(5)
        assert_same set, set.delete(3)
        assert_nil set.delete?(99)
        assert_same set, set.delete?(5)
        assert_includes set, 2
        assert_includes set, 4
        assert_operator set, :===, 4
        assert_equal 2, set.length
        assert_same set, set.clear
        assert_empty set
      end

      assert_empty Set.new(nil)
      assert_raises(ArgumentError) { Set.new(false) }
      assert_raises(ArgumentError) { Set.new(compare_values_by_identity: true) }
    end

    def test_bulk_mutation_and_enumerators
      TYPES.each do |type|
        set = type[1, 2, 3]

        assert_kind_of Enumerator, set.delete_if
        assert_kind_of Enumerator, set.keep_if
        assert_kind_of Enumerator, set.reject!
        assert_kind_of Enumerator, set.select!
        assert_same set, set.merge([3, 4], ::Set[5])
        assert_same set, set.subtract([1, 5])
        assert_same set, set.delete_if(&:even?)
        assert_equal [3], set.to_a
        set.merge([1, 2, 4])

        assert_same set, set.keep_if(&:odd?)
        assert_equal [1, 3], set.to_a.sort
        assert_nil(set.reject! { false })
        assert_nil(set.select! { true })
      end
    end

    def test_nondestructive_operations_preserve_kind
      TYPES.each do |type|
        set = type[1, 2, 3]
        results = [
          set.union([3, 4]), set | [4], set + [4], set.difference([2]), set - [2],
          set.intersection([2, 3, 4]), set & [2, 3], set ^ [3, 4],
          set.select(&:odd?), set.reject(&:odd?)
        ]

        results.each { assert_instance_of type, it, type.name }

        assert_equal [1, 2, 3, 4], results[0].to_a.sort
        assert_equal [1, 3], results[3].to_a.sort
        assert_equal [2, 3], results[5].to_a.sort
        assert_equal [1, 2, 4], results[7].to_a.sort
        assert_equal [1, 2, 3], set.to_a.sort
      end

      local = Set[1].to_set(Local::Set, scope: :thread)

      assert_instance_of Local::Set, local
      assert_equal :thread, local.scope
      assert_equal :local, Set[1].to_set(Set, mode: :local).mode
    end

    def test_relations_equality_and_hashing
      TYPES.each do |type|
        small = type[1]
        same = type[1, 2]
        copy = same.dup
        large = type[1, 2, 3]

        assert_equal same, copy
        assert same.eql?(copy)
        assert_equal same.hash, copy.hash
        assert small.subset?(same)
        assert small.proper_subset?(same)
        assert large.superset?(same)
        assert large.proper_superset?(same)
        assert same.intersect?(type[2, 3])
        assert same.disjoint?(type[3])
        assert_equal(-1, same <=> large)
        assert_equal 0, same <=> copy
        assert_equal 1, same <=> small
        assert_nil(same <=> type[2, 3])
      end
    end

    def test_classify_divide_and_flatten
      TYPES.each do |type|
        set = type[1, 2, 3, 4]
        groups = set.classify(&:even?)

        assert_instance_of type, groups.fetch(true)
        assert_equal [2, 4], groups.fetch(true).to_a.sort
        divided = set.divide(&:even?)

        assert_instance_of Unshared::Set, divided
        assert divided.all?(type)
        assert_equal [[1, 3], [2, 4]], divided.map { it.to_a.sort }.sort
        sorted = type < Abstract::SortedSet
        nested = if sorted
                   [::Set[1].freeze, ::Set[1, 2].freeze]
                 else
                   [::Set[1, 2].freeze, ::Set[3].freeze]
                 end
        expected = sorted ? [1, 2] : [1, 2, 3]
        flattened = type.new(nested)

        assert_equal expected, flattened.flatten.to_a.sort
      end

      assert_equal [1, 2, 3], Unshared::Set.new([::Set[1, 2], ::Set[3]]).flatten.to_a.sort
    end

    def test_sorted_variants_traverse_maintained_order
      [SortedSet, Strict::SortedSet, Unshared::SortedSet, Local::SortedSet].each do |type|
        set = type[3, 1, 2]

        assert_equal [1, 2, 3], set.to_a, type.name
        assert_equal "1-2-3", set.join("-"), type.name
      end
    end

    def test_sorted_variants_use_comparator_membership_and_strict_eql
      sorted_types = [SortedSet, Strict::SortedSet, Unshared::SortedSet, Local::SortedSet]
      sorted_types.each do |type|
        integers = type[1]
        floats = type[1.0]

        assert_includes integers, 1.0, type.name
        assert_nil integers.add?(1.0), type.name
        assert_equal floats, integers, type.name
        refute integers.eql?(floats), type.name
        refute_equal integers, Unshared::Set[1]
        refute_equal Unshared::Set[1], integers
        assert_operator integers, :<=, type[1.0, 2.0], type.name
        assert_equal [1], integers.intersection([1.0]).to_a, type.name
        assert_raises(ArgumentError, type.name) { integers.include?("1") }
      end
    end

    def test_local_sorted_variants_accept_mutable_comparable_elements
      [Unshared::SortedSet, Local::SortedSet].each do |type|
        original = MutableOrderedKey.new(1)
        equivalent = MutableOrderedKey.new(1)
        set = type.new([original])

        assert_includes set, equivalent, type.name
        assert_same original, set.first, type.name
      end
    end

    def test_mutable_comparator_conditional_add_is_atomic
      [Unshared::SortedSet, Local::SortedSet].each do |type|
        set = type.new
        ready = Thread::Queue.new
        start = Thread::Queue.new
        workers = Array.new(8) do |index|
          Thread.new do
            ready << true
            start.pop
            set.add?(MutableOrderedKey.new(index / 8))
          end
        end
        8.times { ready.pop }
        8.times { start << true }

        assert_equal 1, workers.count { it.value.equal?(set) }, type.name
        assert_equal 1, set.size, type.name
      end
    end

    def test_identity_comparison_is_fixed_at_construction
      (TYPES - [SortedSet, Strict::SortedSet, Unshared::SortedSet, Local::SortedSet]).each do |type|
        first = "same".dup.freeze
        second = "same".dup.freeze
        set = type.new([first, second], compare_by_identity: true)

        assert_predicate set, :compare_by_identity?
        assert_equal 2, set.size, type.name
        refute_equal set, type.new([first, second])
        refute_respond_to set, :compare_by_identity
        refute_respond_to set, :reset
      end

      [SortedSet, Strict::SortedSet, Unshared::SortedSet, Local::SortedSet].each do |type|
        assert_raises(ArgumentError) { type.new(compare_by_identity: true) }
      end
    end

    def test_intersection_normalizes_public_operands_once
      set = Unshared::Set.new(["UPPER"], normalize: :downcase)

      assert_equal ["upper"], set.intersection(["UPPER"]).to_a
      assert_equal ["upper"], set.intersection(Unshared::Set["UPPER"]).to_a
      assert_equal ["upper"], set.intersection(set.dup).to_a
      assert_empty Unshared::Set[1].intersection([1.0])
    end

    def test_empty_derived_sets_keep_configuration_and_independent_storage
      normalizer = Ractor.shareable_proc { |value| value + 1 }

      (TYPES - [SortedSet, Strict::SortedSet, Unshared::SortedSet, Local::SortedSet]).each do |type|
        options = type.name.start_with?("Farce::Local::") ? { scope: :thread } : {}
        source = type.new([1, 2], normalize: normalizer, compare_by_identity: true, **options)
        empty = source.__send__(:empty_copy)

        assert_instance_of type, empty
        assert_empty empty
        assert_predicate empty, :compare_by_identity?
        assert_equal source.scope, empty.scope if source.respond_to?(:scope)

        assert_equal source.ractor_shareable?, empty.ractor_shareable?
        empty.add(3)

        assert_equal [4], empty.to_a
        assert_equal [2, 3], source.to_a.sort
      end

      [SortedSet, Strict::SortedSet, Unshared::SortedSet, Local::SortedSet].each do |type|
        options = type.name.start_with?("Farce::Local::") ? { scope: :thread } : {}
        source = type.new([1, 2], normalize: normalizer, **options)
        empty = source.__send__(:empty_copy)

        assert_instance_of type, empty
        assert_empty empty
        assert_equal source.scope, empty.scope if source.respond_to?(:scope)
        empty.add(3)

        assert_equal [4], empty.to_a
        assert_equal [2, 3], source.to_a
      end
    end

    def test_weak_variants_do_not_retain_elements
      strong = build_set_with_unreferenced_member(Strict::Set)
      collect_set_member(strong, attempts: 3)

      assert_equal 1, strong.size

      WEAK_TYPES.each do |type|
        member = Object.new.freeze
        retained = type[member]
        collect_set_member(retained, attempts: 3)

        assert_includes retained, member, type.name

        set = build_set_with_unreferenced_member(type)
        collect_set_member(set)

        assert_empty set, type.name
      end
    end

    def test_recursive_sets_are_safe_to_inspect_and_reject_flattening
      set = Unshared::Set.new
      set.add(set)

      assert_match(/\.\.\./, set.inspect)
      assert_kind_of Integer, set.hash
      assert_raises(ArgumentError) { set.flatten }
    end

    def test_yaml_preserves_configuration_and_current_members
      TYPES.each do |type|
        options = type.name.start_with?("Farce::Local::") ? { scope: :fiber } : {}
        source = type.new(%w[ONE TWO], normalize: :downcase, **options)
        source.freeze unless source.is_a?(Unshareable)
        copy = Psych.unsafe_load(Psych.dump(source))

        assert_instance_of type, copy
        assert_equal source.to_a.sort_by(&:inspect), copy.to_a.sort_by(&:inspect), type.name
        assert_includes copy, "ONE", type.name
        if copy.respond_to?(:scope)
          assert_equal :fiber, copy.scope
          assert_equal copy.to_a.sort, Fiber.new { copy.to_a.sort }.resume
        end
        assert_predicate copy, :frozen? unless copy.is_a?(Unshareable)

        assert_equal source.ractor_shareable?, copy.ractor_shareable?
      end
    end

    def test_yaml_preserves_mode_entries_and_stable_membership
      return unless Internal.native_ractors?

      [Set, SortedSet].each do |type|
        original = [1]
        source = type.new(mode: :copy)
        source.add(original, mode: :local)
        original << 2
        copy = Psych.unsafe_load(Psych.dump(source))

        assert_equal :copy, copy.mode
        assert_equal [[1, 2]], copy.to_a
        assert_includes copy, [1]
        refute_includes copy, [1, 2]
        copy.first << 3

        assert_equal [[1, 2]], source.to_a
      end
    end

    def test_mode_sets_reject_unstable_structural_snapshots
      return unless Internal.native_ractors?

      nested_identity = [Object.new]

      [Set, SortedSet].each do |type|
        error = assert_raises(ArgumentError) { type.new([nested_identity], mode: :local) }
        assert_match(/stable equality snapshot/, error.message)
      end
    end

    private

    def build_set_with_unreferenced_member(type)
      # Keep the producer Thread temporary out of the frame that runs GC.
      # Conservative scans can otherwise retain references from its stack.
      Thread.new do
        set = type.new
        set.add(Object.new.freeze)
        set
      end.value
    end

    def collect_set_member(set, attempts: 50)
      attempts.times do
        2_000.times { Object.new }
        RUBY_ENGINE == "jruby" ? java.lang.System.gc : GC.start
        break if set.empty?
        sleep 0.01
      end
    end
  end
end
