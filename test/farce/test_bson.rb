# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestBSON < Test
    def test_bson_integration
      if RUBY_ENGINE == "jruby" && Gem::Version.new(JRUBY_VERSION) >= Gem::Version.new("10.1") &&
          Gem::Specification.find_by_name("bson").version <= Gem::Version.new("5.2.0")
        skip "BSON 5.2's Java extension instantiates RubyFixnum, which is abstract in JRuby 10.1"
      end
      output, error, status = ruby_isolated(<<~RUBY, timeout: 120)
        ARGV.concat(["--exclude", "test_extended_json_for_collections_and_value_wrappers"])
        require "subprocess/bson"
      RUBY

      assert_predicate status, :success?, "#{output}\n#{error}"
    end

    def test_extended_json
      output, error, status = ruby_isolated(<<~RUBY, timeout: 120)
        ARGV.concat(["--name", "test_extended_json_for_collections_and_value_wrappers"])
        require "subprocess/bson"
      RUBY

      assert_predicate status, :success?, "#{output}\n#{error}"
    end

    def test_bson_is_opt_in
      assert_bson_process(<<~RUBY)
        require "farce"
        raise "BSON was loaded" if defined?(::BSON)
        raise "Vector extension was loaded" if Farce::Vector.method_defined?(:to_bson)
      RUBY
    end

    def test_load_order_and_require_return_values
      ["require", "Kernel.require"].product([true, false]).each do |loader, before|
        setup = before ? "#{loader}(\"bson\"); require \"farce\"" :
          "require \"farce\"; #{loader}(\"bson\")"

        assert_bson_process(<<~RUBY)
          #{setup}
          raise "require result changed" if #{loader}("bson")
          raise "encoder not loaded" unless Farce::Vector.method_defined?(:to_bson)
          raise "integration not loaded" unless Farce::Vector.new([1]).to_bson_normalized_value == [1]
          raise "configuration frozen" if Farce.config.frozen?
        RUBY
      end
    end

    def test_explicit_loading_with_autoload_disabled
      assert_bson_process(<<~RUBY)
        ENV["FARCE_AUTOLOAD_INTEGRATIONS"] = "false"
        require "farce"
        require "bson"
        raise "integration loaded implicitly" if Farce::Vector.method_defined?(:to_bson)
        require "farce/integrations/bson"
        raise "encoder not loaded" unless Farce::Vector.method_defined?(:to_bson)
        raise "integration not loaded" unless Farce::Vector.new([1]).to_bson_normalized_value == [1]
      RUBY
    end

    def test_explicit_integration_loads_dependencies
      assert_bson_process(<<~RUBY)
        require "farce/integrations/bson"
        raise "encoder not loaded" unless Farce::Vector.method_defined?(:to_bson)
        raise "integration not loaded" unless Farce::Vector.new([1]).to_bson_normalized_value == [1]
      RUBY
    end

    private

    def assert_bson_process(source)
      output, error, status = ruby_isolated(source, timeout: 60, coverage: false)

      assert_predicate status, :success?, "#{output}\n#{error}"
    end
  end
end
