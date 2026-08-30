# frozen_string_literal: true

module Helpers
  module Compatibility
    def assert_nothing_raised = yield
    def assert_not_equal(...) = refute_equal(...)
    def assert_not_same(...)  = refute_same(...)
    def assert_not_nil(...)   = refute_nil(...)

    def assert_equal(expected, actual, ...)
      return super unless expected.nil?

      assert_nil(actual, ...)
    end
  end
end
