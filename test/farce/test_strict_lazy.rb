# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "test_lazy"

module Farce
  class TestStrictLazy < TestLazy
    def lazy_class = Strict::Lazy
    def strict_result_options = {}

    def test_rejects_mode_options_for_class_and_block_factories
      assert_raises(ArgumentError) { lazy_class.new(Array, mode: :copy) }
      assert_raises(ArgumentError) { lazy_class.new(mode: :copy) { :ready } }
    end

    def test_rejects_unshareable_results
      return unless Internal.native_ractors?

      lazy = lazy_class.new { [] }

      assert_raises(Ractor::IsolationError) { lazy.value }
      refute_predicate lazy, :frozen?
    end
  end
end
