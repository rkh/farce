# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestFreezeProxies < Test
    include Helpers::InternalTestHelpers

    def test_reference_freezes_current_target_without_freezing_holder
      target = Map.new({ key: :first })
      holder = Atom.new(target, mode: :raise)
      reference = Reference.new(holder)

      assert_same reference, reference.freeze
      assert_predicate target, :frozen?
      refute_predicate holder, :frozen?
      assert_raises(FrozenError) { reference[:key] = :changed }
      replacement = Map.new({ key: :second })
      holder.value = replacement

      refute_predicate reference, :frozen?
      reference[:key] = :changed

      assert_equal :changed, replacement[:key]
      assert_equal :first, target[:key]
      reference.freeze
      copy = reference.dup

      assert_operator Reference, :===, copy
      refute_predicate copy, :frozen?
      copied_holder = Reference.deref(copy)

      refute_same holder, copied_holder
      assert_same replacement, copied_holder.value
      assert_raises(FrozenError) { copy[:key] = :copy }
      copied_holder.value = Map.new({ key: :copy })

      assert_equal :copy, copy[:key]
      assert_same replacement, holder.value
      assert_equal :changed, replacement[:key]
    end

    def test_deep_reference_freezes_materialized_target
      payload = []
      envelope = Envelope::Local.new(payload)
      holder = Atom.new(envelope, mode: :raise)
      reference = Reference.new(holder, deep: true)

      assert_same reference, reference.freeze
      assert_predicate payload, :frozen?
      refute_predicate holder, :frozen?
      assert_raises(FrozenError) { reference << :changed }
    end

    def test_lazy_reference_predicate_does_not_resolve_and_freeze_targets_value
      calls = Counter.new
      reference = LazyRef.new(self: calls) do
        increment
        Counter.new
      end

      refute reference.frozen? # rubocop:disable Minitest/RefutePredicate -- Avoid inspecting the lazy target.
      assert_equal 0, calls.value
      assert_same reference, reference.freeze
      assert_equal 1, calls.value
      assert_predicate reference, :frozen?
      refute_predicate Reference.deref(reference), :frozen?
      assert_raises(FrozenError) { reference.increment }
      assert_same reference, reference.freeze
      assert_equal 1, calls.value
    end

    def test_target_freeze_failure_does_not_repeat_lazy_factory
      calls = Counter.new
      reference = LazyRef.new(self: calls) do
        increment
        Queue.new
      end

      2.times { assert_raises(TypeError) { reference.freeze } }

      refute_predicate reference, :frozen?
      assert_equal 1, calls.value
      reference.push(:still_live)

      assert_equal :still_live, reference.pop
    ensure
      Reference.deref(reference).value.close if reference
    end

    def test_local_lazy_reference_freezes_the_current_scope_target
      calls = Counter.new
      reference = Local::LazyRef.new(scope: :fiber, self: calls) do
        increment
        Counter.new
      end

      refute reference.frozen? # rubocop:disable Minitest/RefutePredicate -- Avoid inspecting the lazy target.
      assert_equal 0, calls.value
      reference.freeze

      assert_predicate reference, :frozen?
      assert_equal 1, calls.value
      observed = Fiber.new do
        before = reference.frozen?
        reference.increment
        reference.freeze
        [before, reference.frozen?, reference.value]
      end.resume

      assert_equal [false, true, 1], observed
      assert_equal 2, calls.value
      assert_predicate reference, :frozen?
      assert_equal 0, reference.value
      refute_predicate Reference.deref(reference), :frozen?
      assert_raises(TypeError) { Reference.deref(reference).freeze }
    end

    def test_weak_value_promotion_preserves_mutable_shareable_target
      target = Counter.new
      value = WeakValue.new(target)

      assert_same value, value.freeze
      assert Ractor.shareable?(value)
      refute_predicate target, :frozen?
      target.increment

      assert_equal 1, value.value.value
      reference = WeakRef.new(target)

      assert_same reference, reference.freeze
      assert_predicate target, :frozen?
      assert_raises(FrozenError) { reference.increment }
      [reference.dup, reference.clone(freeze: false)].each do |copy|
        refute_predicate copy, :frozen?
        assert_same target, copy.__getobj__
        assert_raises(FrozenError) { copy.increment }
      end
    end

    def test_explicit_frozen_weak_value_clone_completes_promotion
      target = [+"mutable"]
      source = WeakValue.new(target)
      copy = source.clone(freeze: true)

      assert_predicate copy, :frozen?
      assert Ractor.shareable?(copy)
      refute_predicate source, :frozen?
      assert_same target, copy.value
      assert_same target, source.value
      assert_predicate target.first, :frozen? if Internal.native_ractors?
    end

    def test_move_envelope_rejects_freeze_without_claiming_or_opening
      envelope = Envelope::Move.new([])

      refute_predicate envelope, :frozen?
      assert Object.instance_method(:frozen?).bind_call(envelope)
      assert Ractor.shareable?(envelope)
      refute_predicate envelope, :claimed?
      assert_raises(TypeError) { envelope.freeze }
      refute_predicate envelope, :claimed?
      value = envelope.value

      assert_predicate envelope, :owned?
      refute_predicate value, :frozen?
      value << :available

      assert_equal [:available], envelope.value
      assert_raises(TypeError) { envelope.freeze }
      refute_predicate envelope, :frozen?
    end
  end
end
