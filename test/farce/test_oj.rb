# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestOj < Test
    def test_oj_integration
      skip "Oj.mimic_JSON is incompatible with TruffleRuby JSON argument forwarding" if RUBY_ENGINE == "truffleruby"
      if RUBY_ENGINE == "jruby" || Gem::Specification.find_all_by_name("oj").empty?
        skip "Oj is unavailable on this engine"
      end
      output, error, status = ruby_subprocess('require "subprocess/oj"', timeout: 180)

      assert_predicate status, :success?, "#{output}\n#{error}"
    end
  end
end
