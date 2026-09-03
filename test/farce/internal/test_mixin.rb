# frozen_string_literal: true

require_relative "../../setup"

module Farce
  module Internal
    class TestMixin < Test
      def test_include_farce_exposes_public_camel_case_constants
        namespace = Module.new { include Farce }

        assert_equal Farce::Clock, namespace.const_get(:Clock)
        assert_equal Farce::Port, namespace.const_get(:Port)
        assert_equal Farce::Ractor, namespace.const_get(:Ractor)
        assert_equal Farce::ReadWriteLock, namespace.const_get(:ReadWriteLock)
      end

      def test_include_farce_does_not_define_constants_on_receiver
        namespace = Module.new { include Farce }

        assert_empty namespace.constants(false)
      end

      def test_include_farce_hides_private_and_internal_constants
        namespace = Module.new { include Farce }

        refute namespace.const_defined?(:Internal)
        refute namespace.const_defined?(:MAYBE)
        refute namespace.const_defined?(:UNDEFINED)
        refute namespace.const_defined?(:VERSION)
        refute namespace.const_defined?(:TestMixin)
      end

      def test_include_farce_hides_test_constants
        namespace = Module.new { include Farce }
        mixin = namespace.ancestors.fetch(1)

        refute_includes mixin.constants(false), :Test
        refute_includes mixin.constants(false), :TestMixin
      end
    end
  end
end
