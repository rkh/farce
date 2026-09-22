# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestIntegrations < Test
    def test_core_does_not_load_optional_dependencies
      assert_integration_process(<<~RUBY)
        require "farce"
        raise "loaded dry-types" if defined?(Dry::Types)
        raise "loaded ActiveSupport" if defined?(ActiveSupport)
        raise "unexpected active integrations" unless Farce::Integrations.load_active.empty?
      RUBY
    end

    def test_zeitwerk_loaded_before_farce_preserves_require_and_integrations
      ["require", "Kernel.require"].each do |loader|
        assert_integration_process(<<~RUBY)
          require "zeitwerk"
          require "farce"
          raise "first require should return true" unless #{loader}("dry/types")
          types = Module.new { include Dry.Types(); include Farce.DryTypes() }
          raise "integration is not usable" unless types::Vector[[1]].to_a == [1]
          raise "second require should return false" if #{loader}("dry/types")
          require "shellwords"
          Kernel.require "shellwords"
        RUBY
      end
    end

    def test_dependencies_loaded_before_farce_activate_integrations
      assert_integration_process(<<~RUBY)
        require "dry/types"
        require "farce"
        raise "dry-types integration missing" unless Farce.respond_to?(:DryTypes)
        raise "wrong active integrations" unless Farce::Integrations.load_active == [:dry_types]
        Kernel.require "shellwords"
      RUBY
      assert_integration_process(<<~RUBY)
        require "active_support"
        require "active_support/core_ext"
        require "farce"
        raise "ActiveSupport integration missing" unless Farce::Vector.method_defined?(:in_groups)
        raise "wrong active integrations" unless Farce::Integrations.load_active == [:active_support]
      RUBY
    end

    def test_dependencies_loaded_after_farce_activate_integrations
      assert_integration_process(<<~RUBY)
        require "farce"
        raise "first require should return true" unless require("dry/types")
        raise "dry-types integration missing" unless Farce.respond_to?(:DryTypes)
        raise "second require should return false" if require("dry/types")
        vector = Module.new { include Dry.Types(); include Farce.DryTypes() }::Vector[[1]]
        raise "integration is not usable" unless vector.to_a == [1]
      RUBY
      assert_integration_process(<<~RUBY)
        require "farce"
        require "active_support"
        raise "integration loaded too early" if Farce::Vector.method_defined?(:in_groups)
        raise "base gem was treated as core_ext" unless Farce::Integrations.load_active.empty?
        require "active_support/core_ext"
        raise "ActiveSupport integration missing" unless Farce::Vector.method_defined?(:in_groups)
      RUBY
    end

    def test_kernel_require_activates_integrations_and_preserves_return_values
      assert_integration_process(<<~RUBY)
        require "farce"
        raise "first require should return true" unless Kernel.require("dry/types")
        raise "dry-types integration missing" unless Farce.respond_to?(:DryTypes)
        raise "second require should return false" if Kernel.require("dry/types")
      RUBY
    end

    def test_require_accepts_rb_suffix_and_path_objects
      assert_integration_process(<<~RUBY)
        require "farce"
        path = Object.new
        def path.to_path = "dry/types.rb"
        require path
        raise "dry-types integration missing" unless Farce.respond_to?(:DryTypes)
      RUBY
    end

    def test_require_visibility_is_preserved
      assert_integration_process(<<~RUBY)
        require "farce"
        raise "require became public" if Object.public_method_defined?(:require)
        raise "require is not private" unless Object.private_method_defined?(:require)
        raise "Kernel.require is not public" unless Kernel.respond_to?(:require)
      RUBY
    end

    def test_load_available_loads_integrations_without_freezing_configuration
      assert_integration_process(<<~RUBY)
        require "farce"
        expected = [:active_support, :dry_types]
        raise "wrong available integrations" unless Farce::Integrations.load_available == expected
        raise "dry-types integration missing" unless Farce.respond_to?(:DryTypes)
        raise "ActiveSupport integration missing" unless Farce::Vector.method_defined?(:in_groups)
        raise "repeat changed result" unless Farce::Integrations.load_available == expected
        raise "wrong active integrations" unless Farce::Integrations.load_active == expected
        raise "configuration was frozen" if Farce.config.frozen?
      RUBY
    end

    def test_load_available_skips_missing_optional_dependencies
      {
        ["active_support"]               => [:dry_types],
        ["dry/types"]                    => [:active_support],
        ["active_support", "dry/types"]  => [],
        ["farce/integrations/dry_types"] => [:active_support],
      }.each do |missing, expected|
        assert_integration_process(<<~RUBY)
          require "farce"
          #{missing_dependencies(missing)}
          result = Farce::Integrations.load_available
          raise "wrong available integrations: \#{result.inspect}" unless result == #{expected.inspect}
        RUBY
      end
    end

    def test_load_available_does_not_hide_missing_transitive_dependencies
      assert_integration_process(<<~RUBY)
        require "farce"
        #{missing_dependencies(["dry/core"])}
        begin
          Farce::Integrations.load_available
          raise "transitive dependency failure was swallowed"
        rescue LoadError => error
          raise "wrong missing dependency" unless error.path == "dry/core"
        end
      RUBY
    end

    def test_unrelated_requires_preserve_load_errors
      assert_integration_process(<<~RUBY)
        require "farce"
        begin
          require "farce_test_nonexistent_feature"
          raise "missing feature was swallowed"
        rescue LoadError => error
          raise "wrong missing feature" unless error.path == "farce_test_nonexistent_feature"
        end
      RUBY
    end

    private

    def assert_integration_process(source)
      output, error, status = ruby_subprocess(source, timeout: 60)

      assert_predicate status, :success?, "#{output}\n#{error}"
    end

    def missing_dependencies(paths)
      <<~RUBY
        module MissingIntegrationDependencies
          def require(path, ...)
            if #{paths.inspect}.include?(path)
              error = LoadError.new("optional dependency unavailable")
              error.define_singleton_method(:path) { path }
              raise error
            end
            super
          end
        end
        Object.prepend(MissingIntegrationDependencies)
      RUBY
    end
  end
end
