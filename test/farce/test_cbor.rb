# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestCBOR < Test
    def test_cbor_integration
      skip "CBOR is unavailable on this Ruby" if Gem::Specification.find_all_by_name("cbor").empty?

      assert_cbor_process('require "subprocess/cbor"')
    end

    def test_cbor_is_opt_in
      assert_cbor_process(<<~RUBY)
        require "farce"
        raise "CBOR was loaded" if defined?(::CBOR)
        raise "Vector extension was loaded" if Farce::Vector.method_defined?(:to_cbor)
      RUBY
    end

    def test_cbor_load_order_preserves_require_return_values
      skip "CBOR is unavailable on this Ruby" if Gem::Specification.find_all_by_name("cbor").empty?

      ["require", "Kernel.require"].product([true, false]).each do |loader, before|
        setup = before ? "#{loader}(\"cbor\"); require \"farce\"" :
          "require \"farce\"; #{loader}(\"cbor\")"

        assert_cbor_process(<<~RUBY)
          #{setup}
          raise "require result changed" if #{loader}("cbor")
          raise "wrong active integrations" unless Farce::Integrations.load_active == [:cbor, :weakref]
          source = Farce::Vector.new([Farce::Counter.new(3)])
          raise "wrong encoding" unless CBOR.decode(CBOR.encode(source)) == [3]
          raise "configuration frozen" if Farce.config.frozen?
        RUBY
      end
    end

    def test_explicit_cbor_integration_with_autoload_disabled
      skip "CBOR is unavailable on this Ruby" if Gem::Specification.find_all_by_name("cbor").empty?

      assert_cbor_process(<<~RUBY)
        ENV["FARCE_AUTOLOAD_INTEGRATIONS"] = "false"
        require "farce"
        require "cbor"
        raise "extension loaded implicitly" if Farce::Vector.method_defined?(:to_cbor)
        require "farce/integrations/cbor"
        raise "wrong encoding" unless CBOR.decode(Farce::Vector.new([1]).to_cbor) == [1]
      RUBY
    end

    def test_explicit_cbor_integration_loads_farce
      skip "CBOR is unavailable on this Ruby" if Gem::Specification.find_all_by_name("cbor").empty?

      assert_cbor_process(<<~RUBY)
        require "farce/integrations/cbor"
        raise "wrong encoding" unless CBOR.decode(CBOR.encode(Farce::Map.new({ "a" => 1 }))) == { "a" => 1 }
      RUBY
    end

    private

    def assert_cbor_process(source)
      output, error, status = ruby_isolated(source, timeout: 180, coverage: false)

      assert_predicate status, :success?, "#{output}\n#{error}"
    end
  end
end
