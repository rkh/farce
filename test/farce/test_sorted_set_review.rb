# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestSortedSetReview < Test
    TYPES = [SortedSet, Strict::SortedSet, Unshared::SortedSet, Local::SortedSet].freeze

    Key = Data.define(:rank, :label) do
      def <=>(other)
        Thread.current[:sorted_set_comparisons] = Thread.current[:sorted_set_comparisons].to_i + 1
        rank <=> other.rank
      end
    end

    def test_membership_uses_ordering_equivalence
      first = Key.new(1, :first)
      equivalent = Key.new(1, :second)
      TYPES.each do |type|
        set = type.new([first])

        assert_includes set, equivalent, type.name
        assert_nil set.add?(equivalent), type.name
        assert_equal 1, set.size, type.name
        assert_same set, set.delete?(equivalent), type.name
        assert_empty set, type.name
      end
    end

    def test_incomparable_insertion_fails_without_changing_contents
      TYPES.each do |type|
        set = type.new([1, 2, 3])

        assert_raises(ArgumentError, type.name) { set.add("incomparable") }
        assert_equal [1, 2, 3], set.to_a, type.name
      end
    end

    def test_ascending_insertion_stays_balanced_and_traversal_does_not_sort
      keys = Array.new(512) { Key.new(it, :entry) }
      TYPES.each do |type|
        Thread.current[:sorted_set_comparisons] = 0
        set = type.new(keys)

        assert_operator Thread.current[:sorted_set_comparisons], :<, 40_000, type.name
        Thread.current[:sorted_set_comparisons] = 0

        2.times { assert_equal keys, set.to_a, type.name }

        assert_equal 0, Thread.current[:sorted_set_comparisons], type.name
        assert_includes set, keys[256], type.name
        assert_operator Thread.current[:sorted_set_comparisons], :<, 100, type.name
      end
    ensure
      Thread.current[:sorted_set_comparisons] = nil
    end
  end
end
