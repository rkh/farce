# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestActiveSupportSets < Test
    def test_active_support_set_extensions
      output, error, status = ruby_subprocess('require "support/active_support_sets"', timeout: 60)

      assert_predicate status, :success?, "#{output}\n#{error}"
    end
  end
end
