# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestExtension < Test
    class Target
      def answer = 20
    end

    Refinements = Extension.define(Target) do
      def answer = super * 2
    end

    module Refined
      using Refinements

      def self.answer(target) = target.answer
    end

    def test_creation_from_another_ractor
      worker = Ractor.new do
        Farce::Extension.new
        :created
      rescue Ractor::IsolationError
        :rejected
      end
      result = worker.respond_to?(:value) ? worker.value : worker.take
      expected = Ractor.builtin? ? :rejected : :created

      assert_equal expected, result
    end

    def test_refinements_are_scoped
      assert_equal 40, Refined.answer(Target.new)
      assert_equal 20, Target.new.answer
    end

    def test_install_prepends_methods_to_multiple_targets
      first = Class.new { def answer = 20 }
      second = Class.new { def answer = 30 }
      extension = Extension.define(first, second) { define_method(:answer) { super() + 1 } }

      assert_equal 20, first.new.answer
      assert_equal 30, second.new.answer
      extension.install

      assert_equal 21, first.new.answer
      assert_equal 31, second.new.answer
    end

    def test_constructor_and_repeated_definitions
      target = Class.new
      extension = Extension.new do
        define(target) { define_method(:first) { 1 } }
      end

      assert_same extension, extension.define(target) { define_method(:second) { 2 } }
      extension.install

      assert_equal 1, target.new.first
      assert_equal 2, target.new.second
    end

    def test_install_is_idempotent_and_yields_once
      target = Class.new { def answer = 20 }
      extension = Extension.define(target) { define_method(:answer) { super() + 1 } }
      calls = 0

      extension.install { calls += 1 }

      refute(extension.install { calls += 1 })
      assert_equal 1, calls
      assert_equal 21, target.new.answer
    end

    def test_definitions_added_after_install_are_installed
      first = Class.new
      second = Class.new
      extension = Extension.define(first) { define_method(:first) { 1 } }
      extension.install
      extension.define(first) { define_method(:second) { 2 } }
      extension.define(second) { define_method(:third) { 3 } }

      assert_equal 1, first.new.first
      assert_equal 2, first.new.second
      assert_equal 3, second.new.third
    end

    def test_frozen_extension_can_be_installed_but_not_extended
      target = Class.new
      extension = Extension.define(target) { define_method(:answer) { 42 } }

      assert_same extension, extension.freeze
      assert_same extension, extension.freeze
      assert_predicate extension, :frozen?
      assert_raises(FrozenError) { extension.define(target) { define_method(:other) { 1 } } }
      extension.install

      assert_equal 42, target.new.answer
    end
  end
end
