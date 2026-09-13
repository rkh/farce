# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestSystem < Test
    def test_windows_matches_the_current_platform
      assert_equal Gem.win_platform?, System.windows?
    end

    def test_windows_can_be_checked_from_another_ractor
      expected = System.windows?
      worker = Ractor.new { System.windows? }

      assert_equal expected, worker.respond_to?(:value) ? worker.value : worker.take
    end
  end
end
