# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "farce/integrations/concurrent"
require "farce/integrations/active_support"
require "farce/integrations/sorted_set" unless Gem::Specification.find_all_by_name("sorted_set").empty?

module Farce
  class TestEnfarceIntegrations < Test
    NAMESPACES = [Farce, Local, Strict, Unsafe, Unshared].freeze

    def test_concurrent_map_conversion_recurses_and_preserves_source
      NAMESPACES.each do |namespace|
        source = ::Concurrent::Map.new
        source[:values] = [1, { members: ::Set[2] }]
        result = namespace.enfarce(source)

        assert_instance_of namespace::Map, result
        assert_instance_of namespace::Vector, result[:values]
        assert_instance_of namespace::Map, result[:values][1]
        assert_instance_of namespace::Set, result[:values][1][:members]
        assert_equal [2], result[:values][1][:members].to_a
        result[:values] << 3

        assert_equal [1, { members: ::Set[2] }], source[:values]
        refute_same source, result
      end
    end

    def test_concurrent_map_conversion_preserves_shared_values_and_cycles
      NAMESPACES.each do |namespace|
        source = ::Concurrent::Map.new
        shared = [1]
        source[:first] = source[:second] = shared
        source[:self] = source
        result = namespace.enfarce(source)

        assert_same result[:first], result[:second]
        assert_same result, result[:self]
      end
    end

    def test_indifferent_access_is_retained_on_nested_hashes
      NAMESPACES.each do |namespace|
        source = ::ActiveSupport::HashWithIndifferentAccess.new(items: [{ name: :ruby }], 1 => :number)
        result = namespace.enfarce(source)

        assert_instance_of namespace::Map, result
        assert_instance_of namespace::Vector, result[:items]
        assert_same result[:items], result["items"]
        assert_instance_of namespace::Map, result[:items][0]
        assert_equal :ruby, result[:items][0][:name]
        assert_equal :ruby, result["items"][0]["name"]
        assert_equal :number, result[1]
        assert_nil result["1"]
        result[:added] = 2

        assert_equal 2, result["added"]
        refute source.key?(:added)
      end
    end

    def test_indifferent_access_conversion_preserves_freezing_and_callback
      [Farce, Local, Strict].each do |namespace|
        source = ::ActiveSupport::HashWithIndifferentAccess.new(name: "ruby").freeze
        result = namespace.enfarce(source, &:to_sym)

        assert_predicate result, :frozen?
        assert_equal :ruby, result[:name]
        assert_equal :ruby, result["name"]
        refute_predicate namespace.enfarce(source, freeze: false, &:to_sym), :frozen?
      end
    end

    def test_sorted_set_conversion_uses_sorted_variant
      skip "sorted_set is not installed on this runtime" if Gem::Specification.find_all_by_name("sorted_set").empty?

      NAMESPACES.each do |namespace|
        source = ::SortedSet[3, 1, 2]
        result = namespace.enfarce({ values: source }) { it * 2 }

        assert_instance_of namespace::SortedSet, result[:values]
        assert_equal [2, 4, 6], result[:values].to_a
        result[:values] << 0

        assert_equal [1, 2, 3], source.to_a
      end
    end

    def test_sorted_set_conversion_recurses_into_elements
      skip "sorted_set is not installed on this runtime" if Gem::Specification.find_all_by_name("sorted_set").empty?

      NAMESPACES.each do |namespace|
        result = namespace.enfarce(::SortedSet[[1]])

        assert_equal [[1]], result.to_a.map(&:to_a)
        result.each { assert_instance_of namespace::Vector, it }
      end
    end

    def test_options_reach_integration_converters
      source = ::Concurrent::Map.new
      source[:values] = [1]
      mode_map = Farce.enfarce(source, mode: :raise)
      local_map = Local.enfarce(source, scope: :fiber)
      indifferent = ::ActiveSupport::HashWithIndifferentAccess.new(values: [1])
      mode_indifferent = Farce.enfarce(indifferent, mode: :raise)
      local_indifferent = Local.enfarce(indifferent, scope: :thread)

      assert_equal :raise, mode_map.mode
      assert_equal :raise, mode_map[:values].mode
      assert_equal :fiber, local_map.scope
      assert_equal :fiber, local_map[:values].scope
      assert_equal :raise, mode_indifferent.mode
      assert_equal :raise, mode_indifferent[:values].mode
      assert_equal :thread, local_indifferent.scope
      assert_equal :thread, local_indifferent[:values].scope
      return if Gem::Specification.find_all_by_name("sorted_set").empty?

      assert_equal :raise, Farce.enfarce(::SortedSet[1], mode: :raise).mode
      assert_equal :fiber, Local.enfarce(::SortedSet[1], scope: :fiber).scope
    end
  end
end
