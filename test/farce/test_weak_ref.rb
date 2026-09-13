# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestWeakRef < Test
    include Helpers::InternalTestHelpers
    include Helpers::WeakReferenceHelpers

    def test_delegates_to_the_original_object
      value = []
      reference = WeakRef.new(value)

      assert_same value, reference.__getobj__
      assert_predicate reference, :weakref_alive?
      assert_respond_to reference, :push
      reference.push(:item)

      assert_equal [:item], value
      assert_equal 1, reference.length
    end

    def test_nil_and_false_remain_alive
      [nil, false].each do |value|
        reference = WeakRef.new(value)

        value.nil? ? assert_nil(reference.__getobj__) : assert_same(value, reference.__getobj__)

        assert_predicate reference, :weakref_alive?
        assert_equal value.to_s, reference.to_s
      end
    end

    def test_setobj_does_not_replace_the_reference
      value = []
      reference = WeakRef.new(value)

      assert_nil reference.__setobj__(:replacement)
      assert_same value, reference.__getobj__
    end

    def test_collected_values_raise_the_compatible_error
      reference = collected_reference(WeakRef)

      assert_same WeakRefError, WeakRef::RefError
      refute_predicate reference, :weakref_alive?
      assert_raises(WeakRef::RefError) { reference.__getobj__ }
      assert_raises(WeakRef::RefError) { reference.to_s }
    end

    def test_shareable_reference_delegates_in_another_ractor
      reference = Ractor.make_shareable(WeakRef.new(:shared))
      worker = Ractor.new(reference) { |shared| [shared.to_s, shared.weakref_alive?] }

      assert_equal ["shared", true], ractor_value(worker)
    end

    def test_moved_values_are_no_longer_alive
      return unless Internal.native_ractors?

      value = []
      reference = WeakRef.new(value)
      worker = Ractor.new do
        received = Ractor.receive
        Ractor.receive
        received.length
      end
      worker.send(value, move: true)

      refute_predicate reference, :weakref_alive?
      assert_raises(WeakRef::RefError) { reference.__getobj__ }
      assert_raises(WeakRef::RefError) { reference.length }
    ensure
      if worker
        worker.send(:done)

        assert_equal 0, ractor_value(worker)
      end
    end
  end
end
