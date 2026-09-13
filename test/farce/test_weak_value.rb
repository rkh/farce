# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "pp"

module Farce
  class TestWeakValue < Test
    include Helpers::InternalTestHelpers
    include Helpers::WeakReferenceHelpers

    def test_live_mutable_value_is_returned_without_delegation
      value = []
      reference = WeakValue.new(value)

      assert_kind_of Abstract::Value, reference
      assert_same value, reference.value
      assert_same value, reference.unwrap
      assert_predicate reference, :alive?
      refute_predicate reference, :moved?
      refute_predicate reference, :frozen?
      refute_respond_to reference, :push

      if Internal.native_ractors?
        refute_predicate reference, :ractor_shareable?
        refute_predicate reference, :frozen?
      else
        assert_predicate reference, :ractor_shareable?
      end

      refute_predicate value, :frozen?
    end

    def test_nil_is_a_live_shareable_singleton
      reference = WeakValue.new(nil)

      assert_same reference, WeakValue.new(nil)
      assert_nil reference.value
      assert_nil reference.unwrap
      assert_predicate reference, :alive?
      refute_predicate reference, :moved?
      assert_predicate reference, :frozen?
      assert_predicate reference, :ractor_shareable?
      assert Ractor.shareable?(reference)
      assert_same reference, reference.freeze
    end

    def test_false_is_alive
      reference = WeakValue.new(false)

      assert_same false, reference.value
      assert_predicate reference, :alive?
      refute_predicate reference, :moved?
    end

    def test_shareable_value_can_be_read_in_another_ractor
      reference = WeakValue.new(:shared)

      assert_predicate reference, :ractor_shareable?
      assert Ractor.shareable?(reference)

      worker = Ractor.new(reference) { |shared| [shared.value, shared.alive?] }

      assert_equal [:shared, true], ractor_value(worker)
    end

    def test_freeze_makes_the_original_value_deeply_shareable
      value = [+"mutable"]
      reference = WeakValue.new(value)

      assert_same reference, reference.freeze
      assert_same reference, reference.freeze
      assert_same value, reference.value

      if Internal.native_ractors?
        assert_predicate value, :frozen?
        assert_predicate value.first, :frozen?
      else
        refute_predicate value, :frozen?
        refute_predicate value.first, :frozen?
      end

      assert Ractor.shareable?(value)
      assert Ractor.shareable?(reference)
    end

    def test_freeze_rejects_an_unshareable_value_without_losing_it
      value = Unshared::Queue.new
      reference = WeakValue.new(value)

      error_class = Internal.native_ractors? ? NoMethodError : Ractor::IsolationError

      assert_raises(error_class) { reference.freeze }
      refute_predicate reference, :frozen?
      assert_same value, reference.value
      assert_predicate reference, :alive?
    end

    def test_collected_values_are_recycled_and_can_be_frozen
      [false, true].each do |freeze_value|
        reference = collected_reference(WeakValue, freeze_value: freeze_value)

        refute_predicate reference, :alive?
        refute_predicate reference, :moved?
        assert_raises(WeakRefError) { reference.value }
        assert_raises(WeakRefError) { reference.unwrap }
        assert_equal "#<Farce::WeakValue state=:recycled>", reference.inspect
        assert_equal reference.inspect, reference.pretty_inspect.chomp
        assert_same reference, reference.freeze
        assert Ractor.shareable?(reference)
        refute_predicate reference, :alive?
      end
    end

    def test_inspect_and_pretty_print_include_live_values
      [nil, false, :value].each do |value|
        reference = WeakValue.new(value)

        assert_equal "#<Farce::WeakValue state=:alive value=#{value.inspect}>", reference.inspect
        assert_equal reference.inspect, reference.pretty_inspect.chomp
      end
    end

    def test_moved_value_is_unreachable
      return unless Internal.native_ractors?

      value = []
      reference = WeakValue.new(value)
      worker = Ractor.new do
        received = Ractor.receive
        Ractor.receive
        received.length
      end
      worker.send(value, move: true)

      refute_predicate reference, :alive?
      assert_predicate reference, :moved?
      assert_raises(WeakRefError) { reference.value }
      assert_equal "#<Farce::WeakValue state=:moved>", reference.inspect
      assert_equal reference.inspect, reference.pretty_inspect.chomp
    ensure
      if worker
        worker.send(:done)

        assert_equal 0, ractor_value(worker)
      end
    end
  end
end
