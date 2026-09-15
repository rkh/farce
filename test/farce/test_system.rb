# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestSystem < Test
    def test_cpu_count_defaults_to_all_cpus
      assert_equal Etc.nprocessors, System.cpu_count
      assert_equal System.cpu_count, System.cpu_count(nil)
    end

    def test_cpu_count_for_each_type
      %i[performance efficiency].each do |type|
        method = :"#{type}_cpu_count"
        expected = Internal::Darwin.public_send(method) if defined?(Internal::Darwin) &&
          Internal::Darwin.respond_to?(method)
        if expected
          assert_equal expected, System.cpu_count(type)
        else
          assert_nil System.cpu_count(type)
        end
      end
    end

    def test_cpu_count_rejects_invalid_types
      [:all, "performance", false, 1].each do |type|
        assert_raises(ArgumentError) { System.cpu_count(type) }
      end
    end

    def test_cpu_count_without_platform_support
      output, error, status = ruby_subprocess(<<~RUBY)
        require "farce"
        internal = Farce.const_get(:Internal, false)
        internal.send(:remove_const, :Darwin) if internal.const_defined?(:Darwin, false)
        abort "incorrect total" unless Farce::System.cpu_count == Etc.nprocessors
        abort "unexpected performance count" unless Farce::System.cpu_count(:performance).nil?
        abort "unexpected efficiency count" unless Farce::System.cpu_count(:efficiency).nil?
      RUBY

      assert_predicate status, :success?, "#{output}\n#{error}"
    end

    def test_cpu_count_can_be_checked_from_another_ractor
      expected = [System.cpu_count, System.cpu_count(:performance), System.cpu_count(:efficiency)]
      worker = Ractor.new { [System.cpu_count, System.cpu_count(:performance), System.cpu_count(:efficiency)] }

      assert_equal expected, worker.respond_to?(:value) ? worker.value : worker.take
    end

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
