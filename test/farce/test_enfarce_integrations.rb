# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestEnfarceIntegrations < Test
    def test_optional_converters
      output, error, status = ruby_isolated('require "subprocess/enfarce"', timeout: 60)

      assert_predicate status, :success?, "#{output}\n#{error}"
    end

    def test_sorted_set_load_order_and_require_return_values
      skip "sorted_set is not installed on this runtime" if Gem::Specification.find_all_by_name("sorted_set").empty?

      ["require", "Kernel.require"].product([true, false]).each do |loader, before|
        setup = before ? "#{loader}(\"sorted_set\"); require \"farce\"" :
          "require \"farce\"; #{loader}(\"sorted_set\")"
        output, error, status = ruby_isolated(<<~RUBY, coverage: false)
          #{setup}
          raise "require result changed" if #{loader}("sorted_set")
          raise "wrong active integrations" unless Farce::Integrations.load_active == [:sorted_set, :weakref]
          result = Farce.enfarce(SortedSet[3, 1, 2])
          raise "wrong result class" unless result.instance_of?(Farce::SortedSet)
          raise "wrong ordering" unless result.to_a == [1, 2, 3]
          raise "configuration frozen" if Farce.config.frozen?
        RUBY

        assert_predicate status, :success?, "#{output}\n#{error}"
      end
    end

    def test_explicit_sorted_set_integration_loads_farce
      skip "sorted_set is not installed on this runtime" if Gem::Specification.find_all_by_name("sorted_set").empty?

      output, error, status = ruby_isolated(<<~RUBY, coverage: false)
        require "farce/integrations/sorted_set"
        result = Farce.enfarce(SortedSet[2, 1])
        raise "wrong result class" unless result.instance_of?(Farce::SortedSet)
        raise "wrong ordering" unless result.to_a == [1, 2]
      RUBY

      assert_predicate status, :success?, "#{output}\n#{error}"
    end

    def test_explicit_sorted_set_integration_with_autoload_disabled
      skip "sorted_set is not installed on this runtime" if Gem::Specification.find_all_by_name("sorted_set").empty?

      output, error, status = ruby_isolated(<<~RUBY, coverage: false)
        ENV["FARCE_AUTOLOAD_INTEGRATIONS"] = "false"
        require "farce"
        require "sorted_set"
        source = SortedSet[3, 1, 2]
        raise "integration loaded implicitly" unless Farce.enfarce(source).instance_of?(Farce::Set)
        require "farce/integrations/sorted_set"
        result = Farce.enfarce(source)
        raise "wrong result class" unless result.instance_of?(Farce::SortedSet)
        raise "wrong ordering" unless result.to_a == [1, 2, 3]
      RUBY

      assert_predicate status, :success?, "#{output}\n#{error}"
    end
  end
end
