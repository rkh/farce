# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "test_lazy_ref"

module Farce
  class TestStrictLazyRef < TestLazyRef
    def reference_class = Strict::LazyRef
    def lazy_class = Strict::Lazy

    def test_requires_shareable_results_and_rejects_modes
      reference = reference_class.new { [] }

      assert_raises(Ractor::IsolationError) { reference.empty? } if Internal.native_ractors?
      assert_raises(ArgumentError) { reference_class.new(Array, mode: :copy) }
    end
  end
end
