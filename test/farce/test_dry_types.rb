# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestDryTypes < Test
    def test_dry_types_integration
      output, error, status = ruby_subprocess('require "subprocess/dry_types"', timeout: 60)

      assert_predicate status, :success?, "#{output}\n#{error}"
    end

    def test_loading_dry_types_does_not_freeze_config
      output, error, status = ruby_subprocess(<<~RUBY)
        require "farce"
        raise "config is already frozen" if Farce.config.frozen?

        require "farce/integrations/dry_types"
        raise "loading dry-types froze config" if Farce.config.frozen?
      RUBY

      assert_predicate status, :success?, "#{output}\n#{error}"
    end

    def test_loading_farce_does_not_load_dry_types
      output, error, status = ruby_subprocess(<<~RUBY)
        require "farce"
        raise "dry-types was loaded by core" if defined?(Dry::Types)
      RUBY

      assert_predicate status, :success?, "#{output}\n#{error}"
    end

    def test_loading_after_zeitwerk_and_dry_types
      sources = [
        <<~RUBY,
          require "farce/integrations/dry_types"
          types = Module.new do
            include Dry.Types()
            include Farce.DryTypes()
          end
          type = types::Vector.of(types::Coercible::Integer)
          raise "direct load failed" unless type[["1"]].to_a == [1]
          require "shellwords"
        RUBY
        <<~RUBY,
          require "zeitwerk"
          require "farce"
          require "farce/integrations/dry_types"
          types = Module.new do
            include Dry.Types()
            include Farce.DryTypes()
          end
          type = types::Vector.of(types::Coercible::Integer)
          raise "Zeitwerk-first load failed" unless type[["1"]].to_a == [1]
          require "shellwords"
        RUBY
        <<~RUBY
          require "dry/types"
          require "farce"
          require "farce/integrations/dry_types"
          types = Module.new do
            include Dry.Types()
            include Farce.DryTypes()
          end
          type = types::Vector.of(types::Coercible::Integer)
          raise "dry-types-first load failed" unless type[["1"]].to_a == [1]
          require "shellwords"
        RUBY
      ]

      sources.each do |source|
        output, error, status = ruby_subprocess(source)

        assert_predicate status, :success?, "#{output}\n#{error}"
      end
    end
  end
end
