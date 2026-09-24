# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestClassMirror < Test
    include Helpers::InternalTestHelpers

    def test_undefined_classes_use_the_base_class
      base = Class.new
      mirror = ClassMirror.new(base)

      assert_same base, mirror[BasicObject]
      assert_same base, mirror[String]
      assert Ractor.shareable?(mirror)
    end

    def test_definitions_mirror_the_source_hierarchy
      mirror = ClassMirror.new
      child = Class.new(Array)
      defined = mirror.define(child)

      assert_same mirror[Array], defined.superclass
      assert_same mirror[Object], mirror[Array].superclass
      assert_same mirror[BasicObject], mirror[Object].superclass
      assert_same defined, mirror[child]
    end

    def test_new_definitions_invalidate_cached_ancestor_lookups
      mirror = ClassMirror.new
      child = Class.new(Array)
      original = mirror[child]
      replacement = mirror.define(Array)

      refute_same original, replacement
      assert_same replacement, mirror[child]
    end

    def test_definition_blocks_support_super_and_repeated_definitions
      mirror = ClassMirror.new
      mirror.define(Object) { define_method(:label) { "object" } }
      mirror.define(Array) { define_method(:label) { "array #{super()}" } }
      original = mirror[Array]
      mirror.define(Array) { define_method(:label) { "new #{super()}" } }

      assert_same original, mirror[Array]
      assert_equal "new array object", mirror[Array].new.label
    end

    def test_constructor_block_is_cached_per_source_class
      mirror = ClassMirror.new { |mapped, source| [mapped, source].freeze }
      array = mirror[Array]
      string = mirror[String]

      assert_same array, mirror[Array]
      assert_same string, mirror[String]
      assert_same array.first, string.first
      assert_same Array, array.last
      assert_same String, string.last
      mirror.define(Array)

      refute_same array, mirror[Array]
      assert_same Array, mirror[Array].last
    end

    def test_rejects_non_class_arguments
      mirror = ClassMirror.new

      [nil, Enumerable, Object.new].each do |value|
        assert_raises(TypeError) { ClassMirror.new(value) }
        assert_raises(TypeError) { mirror[value] }
        assert_raises(TypeError) { mirror.define(value) }
      end
    end

    def test_lookups_work_in_another_ractor_but_definitions_do_not
      mirror = ClassMirror.new
      expected = mirror.define(Array)
      worker = Ractor.new(mirror, expected) do |mapping, klass|
        matches = mapping[Array].equal?(klass)
        rejected = begin
          mapping.define(String)
          false
        rescue Ractor::IsolationError
          true
        end
        [matches, rejected].freeze
      end

      assert_equal [true, true], ractor_value(worker)
    end
  end
end
