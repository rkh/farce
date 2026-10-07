# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestEnfarce < Test
    include Helpers::InternalTestHelpers

    NAMESPACES = [Farce, Local, Strict, Unsafe, Unshared].freeze
    FREEZABLE_NAMESPACES = [Farce, Local, Strict].freeze

    class HashSubclass < ::Hash; end
    class ArraySubclass < ::Array; end
    class SetSubclass < ::Set; end

    def test_converts_nested_containers_in_each_namespace
      NAMESPACES.each do |namespace|
        source = { items: [1, { members: ::Set[2, 3] }], empty: [] }
        result = namespace.enfarce(source)

        assert_instance_of namespace::Map, result
        assert_instance_of namespace::Vector, result[:items]
        assert_instance_of namespace::Map, result[:items][1]
        assert_instance_of namespace::Set, result[:items][1][:members]
        assert_equal [2, 3], result[:items][1][:members].to_a.sort
        assert_instance_of namespace::Vector, result[:empty]
        assert_empty result[:empty]
        assert_equal 1, result[:items][0]
        result[:items] << 4

        assert_equal 2, source[:items].size
        assert_equal({ items: [1, { members: ::Set[2, 3] }], empty: [] }, source)
      end
    end

    def test_subclasses_use_their_ancestor_conversion
      NAMESPACES.each do |namespace|
        assert_instance_of namespace::Map, namespace.enfarce(HashSubclass[a: 1])
        assert_instance_of namespace::Vector, namespace.enfarce(ArraySubclass[1])
        assert_instance_of namespace::Set, namespace.enfarce(SetSubclass[1])
      end
    end

    def test_leaves_unregistered_objects_unchanged
      NAMESPACES.each do |namespace|
        [nil, false, 1, :symbol, Object.new, namespace::Vector.new].each do |value|
          result = namespace.enfarce(value)
          value.nil? ? assert_nil(result) : assert_same(value, result)
        end
      end
    end

    def test_callback_converts_leaves_without_converting_hash_keys
      NAMESPACES.each do |namespace|
        key = Object.new.freeze
        leaf = Object.new
        visited = []
        result = namespace.enfarce({ key => [leaf, ::Set[1]] }) do |value|
          visited << value
          value.equal?(leaf) ? :converted : value + 1
        end

        assert_equal [leaf, 1], visited
        assert_same key, result.keys.first
        assert_equal :converted, result[key][0]
        assert_equal [2], result[key][1].to_a
        assert_equal :converted, namespace.enfarce(leaf) { :converted }
      end
    end

    def test_reuses_converted_containers_and_preserves_mixed_cycles
      NAMESPACES.each do |namespace|
        shared = [1]
        source = { first: shared, second: shared }
        shared << source
        result = namespace.enfarce(source)

        assert_same result[:first], result[:second]
        assert_same result, result[:first][1]
        refute_same source, result
        refute_same shared, result[:first]
        assert_same source, shared[1]
      end
    end

    def test_preserves_source_freezing_by_default
      FREEZABLE_NAMESPACES.each do |namespace|
        source = { frozen: [{ value: 1 }.freeze].freeze, mutable: [{ value: 2 }] }
        result = namespace.enfarce(source.freeze)

        assert_predicate result, :frozen?
        assert_predicate result[:frozen], :frozen?
        assert_predicate result[:frozen][0], :frozen?
        refute_predicate result[:mutable], :frozen?
        refute_predicate result[:mutable][0], :frozen?
      end
    end

    def test_freeze_option_applies_to_every_converted_container
      FREEZABLE_NAMESPACES.product([true, false]).each do |namespace, freeze|
        source = { values: [{ value: 1 }.freeze].freeze }.freeze
        result = namespace.enfarce(source, freeze:)

        assert_equal freeze, result.frozen?
        assert_equal freeze, result[:values].frozen?
        assert_equal freeze, result[:values][0].frozen?
        assert_predicate source, :frozen?
      end
    end

    def test_freezes_sets_in_namespaces_that_support_freezing
      FREEZABLE_NAMESPACES.each do |namespace|
        result = namespace.enfarce(::Set[1].freeze)

        assert_predicate result, :frozen?
        assert_raises(FrozenError) { result << 2 }
        refute_predicate namespace.enfarce(::Set[1].freeze, freeze: false), :frozen?
        assert_predicate namespace.enfarce(::Set[1], freeze: true), :frozen?
      end
    end

    def test_unshared_containers_retain_their_rejection_of_freezing
      [Unshared, Unsafe].product([{ value: 1 }, [1], ::Set[1]]).each do |namespace, source|
        assert_raises(NoMethodError) { namespace.enfarce(source, freeze: true) }
        assert_raises(NoMethodError) { namespace.enfarce(source.freeze) }
        result = namespace.enfarce(source, freeze: false)

        refute_respond_to result, :freeze
        assert_equal 1, result.size
      end
    end

    def test_freeze_option_does_not_freeze_unconverted_leaves
      NAMESPACES.each do |namespace|
        leaf = Object.new

        assert_same leaf, namespace.enfarce(leaf, freeze: true)
        refute_predicate leaf, :frozen?
      end
    end

    def test_frozen_cycles_are_filled_before_freezing
      FREEZABLE_NAMESPACES.product([nil, true]).each do |namespace, freeze|
        source = []
        source << source << 1
        source.freeze if freeze.nil?
        result = namespace.enfarce(source, freeze:)

        assert_same result, result[0]
        assert_equal 1, result[1]
        assert_predicate result, :frozen?
      end
    end

    def test_preserves_identity_hash_keys
      NAMESPACES.each do |namespace|
        first = "key".dup.freeze
        second = "key".dup.freeze
        source = {}.compare_by_identity
        source[first] = [1]
        source[second] = [2]
        result = namespace.enfarce(source)

        assert_predicate result, :compare_keys_by_identity?
        assert_equal 2, result.size
        assert_equal [1], result[first].to_a
        assert_equal [2], result[second].to_a
        assert_nil result["key"]
      end
    end

    def test_converts_weak_maps_and_preserves_key_identity
      NAMESPACES.each do |namespace|
        first = "key".dup.freeze
        second = "key".dup.freeze
        first_value = [1]
        second_value = [2]
        source = ObjectSpace::WeakMap.new
        source[first] = first_value
        source[second] = second_value
        # Retain the source and converted values outside the weak maps.
        result, converted_first, converted_second = namespace.enfarce([source, first_value, second_value]).to_a

        assert_instance_of namespace::WeakMap, result
        assert_predicate result, :compare_keys_by_identity?
        assert_equal 2, result.size
        assert_instance_of namespace::Vector, converted_first
        assert_instance_of namespace::Vector, converted_second
        assert_same converted_first, result[first]
        assert_same converted_second, result[second]
        assert_equal [1], converted_first.to_a
        assert_equal [2], converted_second.to_a
        assert_nil result["key"]
        assert_same first_value, source[first]
        assert_same second_value, source[second]
      end
    end

    def test_preserves_identity_set_membership
      NAMESPACES.each do |namespace|
        first = "member".dup.freeze
        second = "member".dup.freeze
        source = ::Set.new.compare_by_identity
        source.add(first).add(second)
        result = namespace.enfarce(source)

        assert_predicate result, :compare_by_identity?
        assert_equal 2, result.size
        assert_includes result, first
        assert_includes result, second
        refute_includes result, "member"
      end
    end

    def test_conversion_runs_in_another_ractor
      NAMESPACES.each do |namespace|
        worker = Ractor.new(namespace) do |ns|
          result = ns.enfarce({ values: [::Set[1]] })
          [result.instance_of?(ns::Map), result[:values].instance_of?(ns::Vector),
           result[:values][0].instance_of?(ns::Set), result[:values][0].to_a].freeze
        end

        assert_equal [true, true, true, [1]], ractor_value(worker)
      end
    end

    def test_mode_is_forwarded_to_nested_containers
      result = Farce.enfarce({ values: [::Set[1]] }, mode: :raise)

      assert_equal :raise, result.mode
      assert_equal :raise, result[:values].mode
      assert_equal :raise, result[:values][0].mode
      assert_raises(Ractor::IsolationError) { result[:values] << Object.new } if Internal.native_ractors?
    end

    def test_local_scope_is_forwarded_to_nested_containers
      %i[thread fiber].each do |scope|
        result = Local.enfarce({ values: [::Set[1]] }, scope:)

        assert_equal scope, result.scope
        assert_equal scope, result[:values].scope
        assert_equal scope, result[:values][0].scope
      end
    end

    def test_strict_conversion_can_make_leaves_shareable_with_a_callback
      leaf = "mutable".dup
      assert_raises(Ractor::IsolationError) { Strict.enfarce([leaf]) } if Internal.native_ractors?
      result = Strict.enfarce([leaf]) { Ractor.make_shareable(it.freeze) }

      assert_same leaf, result[0]
      assert_predicate leaf, :frozen?
      assert_predicate result, :ractor_shareable?
    end
  end
end
