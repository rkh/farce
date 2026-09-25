# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestActiveSupportClock < Test
    def test_duration_support_requires_the_integration
      output, error, status = ruby_isolated(<<~RUBY, timeout: 60)
        ENV["FARCE_AUTOLOAD_INTEGRATIONS"] = "false"
        require "farce"
        require "active_support"
        require "active_support/core_ext"
        raise "core treats durations specially" unless Farce.clock(601.seconds) == 601.0
        require "farce/integrations/active_support"
        require "subprocess/active_support_clock"
      RUBY

      assert_predicate status, :success?, "#{output}\n#{error}"
    end

    def test_duration_support_with_automatic_integration_loading
      orders = [%w[farce active_support active_support/core_ext], %w[active_support active_support/core_ext farce]]
      orders.each do |order|
        output, error, status = ruby_isolated(<<~RUBY, timeout: 60)
          ENV["FARCE_AUTOLOAD_INTEGRATIONS"] = "true"
          #{order.inspect}.each { require it }
          require "subprocess/active_support_clock"
        RUBY

        assert_predicate status, :success?, "#{order.inspect}: #{output}\n#{error}"
      end
    end
  end
end
