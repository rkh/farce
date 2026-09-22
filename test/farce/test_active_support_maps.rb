# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestActiveSupportMaps < Test
    def test_active_support_map_extensions
      output, error, status = ruby_subprocess(<<~RUBY, timeout: 60)
        require "support/active_support_maps"
        require "support/active_support_indifferent_access"
        require "support/active_support_copy"
      RUBY

      assert_predicate status, :success?, "#{output}\n#{error}"
    end
  end
end
