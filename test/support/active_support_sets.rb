# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "farce/integrations/active_support"

module Farce
  class ActiveSupportSetTests < Test
    TYPES = [
      Set, SortedSet, Strict::Set, Strict::SortedSet, Strict::WeakSet,
      Unshared::Set, Unshared::SortedSet, Unshared::WeakSet,
      Local::Set, Local::SortedSet, Local::WeakSet
    ].freeze

    def test_same_kind_extensions
      TYPES.each do |type|
        set = type.new([1, 2])
        blanks = type.new(["", "value"])

        assert_instance_of type, blanks.compact_blank, type.name
        assert_equal ["value"], blanks.compact_blank.to_a, type.name
        assert_same blanks, blanks.compact_blank!
        assert_equal [1, 2, 3], set.including([2, 3]).to_a.sort, type.name
        assert_equal [2], set.excluding(1).to_a, type.name
        assert_instance_of type, set.deep_dup, type.name
      end
    end

    def test_deep_dup_preserves_configuration_without_renormalizing
      normalizer = Ractor.shareable_proc { |value| value + 1 }

      TYPES.each do |type|
        set = type.new([1, 2], normalize: normalizer)
        copy = set.deep_dup

        assert_instance_of type, copy
        assert_equal [2, 3], copy.to_a.sort, type.name
        assert_equal set.compare_by_identity?, copy.compare_by_identity?
        assert_equal set.scope, copy.scope if set.respond_to?(:scope)
      end

      element = [[1]]
      source = Unshared::Set[element]
      copy = source.deep_dup
      copy.to_a.first.first << 2

      assert_equal [[1]], element
    end

    def test_serialization_and_enumerable_extensions
      set = Set[1, 2]

      assert_equal [1, 2], set.as_json.sort
      assert_equal %w[1 2], set.to_param.split("/").sort
      assert_equal ["ids%5B%5D=1", "ids%5B%5D=2"], set.to_query("ids").split("&").sort
      assert_equal({ 1 => 2, 2 => 4 }, set.index_with { it * 2 })
      assert_equal [1, 2], Unshared::Set.new([{ id: 1 }, { id: 2 }]).pluck(:id).sort
    end
  end
end
