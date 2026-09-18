# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "internal/test_flag"

module Farce
  class TestFlag < Internal::TestFlag
    def test_public_type_and_shareability
      flag = Flag.new

      assert_equal Internal::Flag, Flag.superclass
      assert_kind_of Abstract::Flag, flag
      assert_kind_of Abstract::Value, flag
      assert_predicate flag, :frozen?
      assert_predicate flag, :ractor_shareable?
      assert Ractor.shareable?(flag)
      refute flag.unwrap
      flag.set

      assert flag.unwrap
    end

    def test_only_one_thread_claims_the_flag
      flag = Flag.new
      workers = 8.times.map { Thread.new { flag.compare_and_set(false, true) } }

      assert_equal 1, workers.count(&:value)
      assert flag.value
    end

    private def flag_class = Farce::Flag
  end
end
