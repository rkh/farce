# frozen_string_literal: true

require_relative "../../setup"
require "etc"

module Farce
  module Internal
    class TestDarwin < Test
      if RUBY_ENGINE == "ruby" && RUBY_PLATFORM.include?("darwin")
        def test_exposes_qos_classes
          refute Farce.const_get(:Internal, false).const_defined?(:QoS, false)
          assert_equal(-15, Darwin::MIN_RELATIVE_PRIORITY)
          assert_equal 0x21, Darwin::USER_INTERACTIVE
          assert_equal 0x19, Darwin::USER_INITIATED
          assert_equal 0x15, Darwin::DEFAULT
          assert_equal 0x11, Darwin::UTILITY
          assert_equal 0x09, Darwin::BACKGROUND
          assert_equal 0x00, Darwin::UNSPECIFIED
        end

        def test_gets_main_qos_class
          assert_includes [Darwin::USER_INTERACTIVE, Darwin::USER_INITIATED, Darwin::DEFAULT,
                           Darwin::UTILITY, Darwin::BACKGROUND, Darwin::UNSPECIFIED], Darwin.main_qos_class
        end

        def test_gets_cpu_count
          assert_equal Etc.nprocessors, Darwin.cpu_count
        end

        def test_gets_performance_cpu_count_when_available
          count = Darwin.performance_cpu_count

          assert_nil(count) unless count
          assert_operator count, :>, 0 if count
        end

        def test_gets_efficiency_cpu_count_when_available
          count = Darwin.efficiency_cpu_count

          assert_nil(count) unless count
          assert_operator count, :>, 0 if count
        end

        def test_gets_and_sets_current_threads_qos
          result = Thread.new do
            Darwin.set_qos_class(Darwin::UTILITY, 0)
            Darwin.get_qos_class
          end.value

          assert_equal [Darwin::UTILITY, 0], result
        end

        def test_accepts_a_relative_priority
          result = Thread.new do
            Darwin.set_qos_class(Darwin::BACKGROUND, -1)
            Darwin.get_qos_class
          end.value

          assert_equal [Darwin::BACKGROUND, -1], result
        end

        def test_raises_for_an_invalid_qos_class
          assert_raises(Errno::EINVAL) { Darwin.set_qos_class(Darwin::UNSPECIFIED, 0) }
        end
      else
        def test_darwin_is_not_defined
          refute Farce.const_get(:Internal, false).const_defined?(:Darwin, false)
        end
      end
    end
  end
end
