# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../../setup"

module Farce
  module Internal
    class TestLeaseWaiting < Test
      def test_wait_without_a_deadline
        interval = LeaseWaiting.wait_interval(nil)

        if RUBY_ENGINE == "jruby"
          assert_in_delta 0.05, interval
        else
          assert_nil interval
        end
      end

      def test_long_waits_allow_jruby_cancellation
        expected = RUBY_ENGINE == "jruby" ? 0.05 : 30

        assert_equal expected, LeaseWaiting.wait_interval(30)
      end

      def test_short_and_expired_deadlines_are_preserved
        [0.01, 0.05, 0, -0.01].each do |remaining|
          assert_equal remaining, LeaseWaiting.wait_interval(remaining)
        end
      end
    end
  end
end
