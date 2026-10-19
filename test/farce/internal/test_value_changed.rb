# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../../setup"

module Farce
  module Internal
    class TestValueChanged < Test
      include Helpers::InternalTestHelpers

      class Comparison
        def initialize(result)
          @result = result
        end

        def ==(_other) = @result

        def !=(_other)
          false
        end

        def equal?(_other) = true
      end

      class RaisingComparison
        def ==(_other)
          raise "comparison called"
        end
      end

      def test_identical_observations_skip_equality_callbacks
        [Float::NAN, RaisingComparison.new].each do |value|
          comparisons.each do |compare|
            refute compare.call(value, value, false)
            refute compare.call(value, value, true)
          end
        end
      end

      def test_equal_values_follow_the_comparison_mode
        first = +"value"
        equal = +"value"
        comparisons.each do |compare|
          refute compare.call(first, equal, false)
          assert compare.call(first, equal, true)
          refute compare.call(1, 1, false)
          assert compare.call(1, 2, false)
          assert compare.call(nil, false, false)
        end
      end

      def test_equality_uses_truthiness_and_ignores_overridden_identity_and_inequality
        comparisons.each do |compare|
          [nil, false].each { |result| assert compare.call(Comparison.new(result), Object.new, false) }
          [:equal, 0].each { |result| refute compare.call(Comparison.new(result), Object.new, false) }
        end
      end

      def test_identity_comparison_skips_equality_but_semantic_comparison_propagates_errors
        comparisons.each do |compare|
          current = RaisingComparison.new
          expected = Object.new

          assert compare.call(current, expected, true)
          error = assert_raises(RuntimeError) { compare.call(current, expected, false) }
          assert_equal "comparison called", error.message
        end
      end

      def test_comparison_is_available_inside_a_ractor
        ractor = Ractor.new(Float::NAN) do |value|
          [Internal.value_changed?(value, value, false), Internal.value_changed?(1, 2, false)]
        end

        assert_equal [false, true], ractor_value(ractor)
      end

      private

      def comparisons
        runtime = Internal.method(:value_changed?)
        return [runtime] if runtime.source_location
        [runtime, Internal.instance_method(:value_changed?).bind(Internal)]
      end
    end
  end
end
