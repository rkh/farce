# frozen_string_literal: true

require_relative "../../setup"

module Farce
  module Internal
    class TestMixin < Test
      def test_include_adds_port_to_a_local_ractor_namespace
        ractor = Module.new
        namespace = Module.new
        namespace.const_set(:Ractor, ractor)
        namespace.include(Farce)

        assert_same Farce::Port, ractor.const_get(:Port, false)
      end

      def test_include_preserves_an_existing_local_port
        port = Class.new
        ractor = Module.new
        ractor.const_set(:Port, port)
        namespace = Module.new
        namespace.const_set(:Ractor, ractor)
        namespace.include(Farce)

        assert_same port, ractor.const_get(:Port, false)
      end

      def test_include_farce_exposes_public_camel_case_constants
        namespace = Module.new { include Farce }

        assert_equal Farce::Atom, namespace.const_get(:Atom)
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
