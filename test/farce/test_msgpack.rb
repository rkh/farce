# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestMessagePack < Test
    def test_msgpack_integration
      output, error, status = ruby_subprocess('require "subprocess/msgpack"', timeout: 120)

      assert_predicate status, :success?, "#{output}\n#{error}"
    end

    def test_msgpack_is_opt_in
      output, error, status = ruby_subprocess(<<~RUBY)
        require "farce"
        raise "MessagePack was loaded" if defined?(::MessagePack)
        raise "Vector extension was loaded" if Farce::Vector.method_defined?(:to_msgpack)
      RUBY

      assert_predicate status, :success?, "#{output}\n#{error}"
    end
  end
end
