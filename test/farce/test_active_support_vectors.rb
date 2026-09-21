# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestActiveSupportVectors < Test
    def test_active_support_vector_extensions
      output, error, status = ruby_subprocess('require "support/active_support_vectors"', timeout: 60)

      assert_predicate status, :success?, "#{output}\n#{error}"
    end
  end
end
