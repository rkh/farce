# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestReference < Test
    class Value
      include Abstract::Value

      attr_accessor :value

      def initialize(value, suffix: "", &block)
        @value = block ? block.call(value + suffix) : value
      end
    end

    class Target
      def call(value, offset:, &block) = block.call(value + offset)
    end

    def test_delegates_to_the_current_value
      value = Value.new("first")
      reference = Reference.new(value)

      assert_equal "FIRST", reference.upcase
      value.value = "second"

      assert_equal "SECOND", reference.upcase
      assert_respond_to reference, :upcase
      refute_respond_to reference, :missing_method
      assert_raises(NoMethodError) { reference.missing_method }
    end

    def test_forwards_arguments_keywords_and_blocks
      reference = Reference.new(Value.new(Target.new))

      assert_equal 14, reference.call(3, offset: 4) { it * 2 }
    end

    def test_delegates_methods_that_also_exist_on_value_objects
      target = Object.new
      reference = Reference.new(Value.new(target))

      assert_same Object, reference.class
      assert_same target, reference.itself
      assert_equal target.inspect, reference.inspect
      assert_equal target.object_id, reference.object_id # rubocop:disable Minitest/AssertSame
    end

    # Keep the proxy as the operator receiver, including for nil and false.
    # rubocop:disable-next Minitest/AssertEqual, Minitest/RefuteEqual
    def test_delegates_equality_inequality_and_negation
      value = Value.new(:first)
      reference = Reference.new(value)

      assert_operator reference, :==, :first
      refute_operator reference, :==, :second
      assert_operator reference, :!=, :second
      refute_operator reference, :!=, :first
      refute_predicate reference, :!

      [nil, false].each do |result|
        value.value = result

        assert_operator reference, :==, result
        refute_operator reference, :!=, result
        assert_predicate reference, :!
      end
    end

    def test_evaluates_blocks_in_the_target_context
      target = [1, 2]
      reference = Reference.new(Value.new(target))

      assert_same(target, reference.instance_eval { self })
      assert_equal 7, reference.instance_exec(4) { sum + it }
      assert_equal 3, reference.instance_eval("sum", __FILE__, __LINE__)
    end

    def test_rejects_objects_without_the_value_contract
      [nil, false, Object.new, Struct.new(:value).new(42)].each do |value|
        error = assert_raises(ArgumentError) { Reference.new(value) }

        assert_equal "value must be a Farce::Abstract::Value", error.message
      end
    end

    def test_deref_returns_the_original_value_object
      value = Value.new(:result)
      reference = Reference.new(value)
      another = Reference.new(reference)

      assert_same value, Reference.deref(reference)
      assert_same value, Reference.deref(another)
      refute_same reference, another
      assert_equal :result, another.itself
    end

    def test_deref_leaves_non_references_unchanged
      assert_nil Reference.deref(nil)
      [false, Object.new, BasicObject.new, Value.new(42)].each do |value|
        assert_same value, Reference.deref(value)
      end
    end

    def test_deep_references_unwrap_nested_values
      inner = Value.new("first")
      outer = Value.new(inner)
      shallow = Reference.new(outer)
      deep = Reference.new(outer, deep: true)

      assert_same inner, shallow.itself
      assert_equal "FIRST", deep.upcase
      assert_same outer, Reference.deref(deep)
      inner.value = "second"

      assert_equal "SECOND", deep.upcase
      outer.value = Value.new("third")

      assert_equal "THIRD", deep.upcase
    end

    def test_deep_references_resolve_cycles_to_nil
      value = Value.new(nil)
      value.value = value
      reference = Reference.new(value, deep: true)

      assert_nil reference.itself
    end

    def test_freezes_the_reference_and_current_target
      target = []
      value = Value.new(target)
      reference = Reference.new(value)

      refute_predicate reference, :frozen?
      assert_same reference, reference.freeze
      assert_predicate reference, :frozen?
      assert_predicate target, :frozen?
      refute_predicate value, :frozen?
      assert_raises(FrozenError) { reference.push(:item) }
      value.value = []

      refute_predicate reference, :frozen?
      reference.freeze

      assert_predicate reference, :frozen?
      assert_predicate value.value, :frozen?
    end

    def test_frozen_target_does_not_mean_the_reference_is_frozen
      reference = Reference.new(Value.new("frozen"))

      refute_predicate reference, :frozen?
    end

    def test_deep_freeze_freezes_the_unwrapped_target
      target = []
      inner = Value.new(target)
      reference = Reference.new(Value.new(inner), deep: true)
      reference.freeze

      assert_predicate reference, :frozen?
      assert_predicate target, :frozen?
      refute_predicate inner, :frozen?
    end

    def test_factory_subclasses_forward_constructor_arguments
      klass = Reference[Value]
      reference = klass.new("hello", suffix: "!", &:upcase)

      assert_operator klass, :<, Reference
      assert_same Value, klass.value_factory
      assert_instance_of Value, Reference.deref(reference)
      assert_equal "HELLO!", reference.itself
      refute_respond_to klass, :[]
    end

    def test_factory_is_inherited_by_further_subclasses
      klass = Class.new(Reference[Value]) do
        def doubled = self * 2
      end

      assert_same Value, klass.value_factory
      assert_equal "hellohello", klass.new("hello").doubled
    end

    def test_deep_factory_subclasses_unwrap_nested_values
      klass = Reference[Value, deep: true]
      reference = klass.new(Value.new("hello"))

      assert_equal "HELLO", reference.upcase
      assert_instance_of Value, Reference.deref(reference)
      assert_equal "WORLD", Class.new(klass).new(Value.new("world")).upcase
    end

    def test_rejects_invalid_factories
      [nil, -> { Value.new(42) }, Abstract::Value].each do |factory|
        error = assert_raises(ArgumentError) { Reference[factory] }

        assert_equal "factory must be a class", error.message
      end
      error = assert_raises(ArgumentError) { Reference[Object] }

      assert_equal "factory must include Farce::Abstract::Value", error.message
    end
  end
end
