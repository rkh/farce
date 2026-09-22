# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestActiveSupportBlank < Test
    def test_active_support_blank_extensions
      output, error, status = ruby_subprocess('require "support/active_support_blank"', timeout: 60)

      assert_predicate status, :success?, "#{output}\n#{error}"
    end
  end
end
