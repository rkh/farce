# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestYajl < Test
    def test_yajl_integration
      skip "Yajl encoding is unreliable on TruffleRuby" if RUBY_ENGINE == "truffleruby"

      if RUBY_ENGINE == "jruby" || Gem::Specification.find_all_by_name("yajl-ruby").empty?
        skip "Yajl is unavailable on this Ruby"
      end
      output, error, status = ruby_isolated('require "subprocess/yajl"', timeout: 180)

      assert_predicate status, :success?, "#{output}\n#{error}"
    end
  end
end
