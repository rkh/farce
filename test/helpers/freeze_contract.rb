# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Helpers
  module FreezeContract
    def assert_logical_freeze(object, read:, mutations:)
      refute_predicate object, :frozen?, "#{object.class} should start logically mutable"
      assert Farce::Ractor.shareable?(object), "#{object.class} should remain Ractor-shareable"
      expected = read.call

      assert_same object, object.freeze
      assert_same object, object.freeze
      assert_predicate object, :frozen?
      assert_equal expected, read.call

      mutations.each do |name, mutation|
        assert_raises(FrozenError, "#{object.class}##{name} should reject mutation after freeze", &mutation)
        assert_equal expected, read.call, "#{object.class}##{name} changed frozen state"
      end
    end

    def assert_freeze_rejected(object)
      refute_predicate object, :frozen?, "#{object.class} should start unfrozen"
      assert_raises(TypeError, "#{object.class}#freeze should be rejected") { object.freeze }
      refute_predicate object, :frozen?, "#{object.class} should remain unfrozen after rejecting freeze"
    end

    def assert_frozen_copy_states(source, read:, mutate:)
      expected = read.call(source)
      source.freeze
      duplicated = source.dup
      cloned = source.clone
      unfrozen_clone = source.clone(freeze: false)

      refute_predicate duplicated, :frozen?
      assert_predicate cloned, :frozen?
      refute_predicate unfrozen_clone, :frozen?
      [duplicated, cloned, unfrozen_clone].each do |copy|
        refute_same source, copy
        assert Farce::Ractor.shareable?(copy) if source.respond_to?(:ractor_shareable?) && source.ractor_shareable?

        assert_equal expected, read.call(copy)
      end

      mutate.call(duplicated)

      refute_equal expected, read.call(duplicated)
      assert_equal expected, read.call(source)
      assert_equal expected, read.call(cloned)
      assert_equal expected, read.call(unfrozen_clone)

      mutate.call(unfrozen_clone)

      refute_equal expected, read.call(unfrozen_clone)
      assert_equal expected, read.call(source)
      assert_equal expected, read.call(cloned)
    end
  end
end
