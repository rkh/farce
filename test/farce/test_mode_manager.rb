# frozen_string_literal: true

require_relative "../setup"

module Farce
  class TestModeManager < Test
    include Helpers::InternalTestHelpers

    class Payload
      include Unshareable::Movable
      include Unshareable::Copyable

      attr_accessor :value

      def initialize(value)
        @value = value
      end

      def inspect = "#<Payload #{@value.inspect}>"
    end

    class PermissiveEqualityManager < ModeManager
      def ==(other) = other.is_a?(ModeManager)
    end

    def test_defaults_to_copy_mode_and_is_shareable
      manager = ModeManager.new

      assert_equal :copy, manager.mode
      assert_predicate manager, :frozen?
      assert_predicate manager, :ractor_shareable?
      assert Ractor.shareable?(manager)
    end

    def test_accepts_every_documented_mode
      expected = ::Set[:copy, :move, :local, :make_shareable, :raise, :shareable_copy, :dedup]

      assert_equal expected, ModeManager::MODES
      expected.each do |mode|
        assert_equal mode, ModeManager.new(mode:).mode
      end
    end

    def test_rejects_an_invalid_default_mode
      error = assert_raises(ArgumentError) { ModeManager.new(mode: :invalid) }

      assert_equal "invalid mode: :invalid", error.message
    end

    def test_returns_shareable_values_unchanged
      manager = ModeManager.new(mode: :raise)
      value = %i[already shareable].freeze

      assert_same value, manager.wrap(value)
      assert_same value, manager.unwrap(value)
    end

    def test_returns_basic_objects_unchanged
      manager = ModeManager.new

      assert_same UNDEFINED, manager.unwrap(UNDEFINED)
    end

    def test_copy_mode_wraps_a_snapshot_and_automatically_unwraps_it
      manager = ModeManager.new
      source = Payload.new(:original)
      envelope = manager.wrap(source)
      source.value = :changed

      assert_instance_of Envelope::Copy, envelope
      assert_same manager, envelope.auto_unwrap

      result = manager.unwrap(envelope)

      refute_same source, result
      assert_equal :original, result.value
      assert_same result, manager.unwrap(envelope)
    end

    def test_move_mode_wraps_and_automatically_unwraps_the_value
      manager = ModeManager.new(mode: :move)
      envelope = manager.wrap(Payload.new(:value))

      assert_instance_of Envelope::Move, envelope
      assert_same manager, envelope.auto_unwrap
      assert_equal :value, manager.unwrap(envelope).value
    end

    def test_local_mode_wraps_and_automatically_unwraps_the_value
      manager = ModeManager.new(mode: :local)
      source = Payload.new(:value)
      envelope = manager.wrap(source)

      assert_instance_of Envelope::Local, envelope
      assert_same manager, envelope.auto_unwrap
      assert_same source, manager.unwrap(envelope)
    end

    def test_raise_mode_rejects_an_unshareable_value
      manager = ModeManager.new(mode: :raise)
      value = Payload.new(:value)

      error = assert_raises(Ractor::IsolationError) { manager.wrap(value) }

      assert_equal "value is not Ractor-shareable: #<Payload :value>", error.message
    end

    def test_make_shareable_mode_returns_the_original_value
      manager = ModeManager.new(mode: :make_shareable)
      value = [[:mutable]]
      result = manager.wrap(value)

      assert_same value, result
      assert Ractor.shareable?(result)
      assert_predicate result, :frozen? if Internal.native_ractors?
      assert_predicate result.first, :frozen? if Internal.native_ractors?
    end

    def test_shareable_copy_mode_preserves_the_original_value
      manager = ModeManager.new(mode: :shareable_copy)
      value = [[:mutable]]
      result = manager.wrap(value)

      assert Ractor.shareable?(result)
      if Internal.native_ractors?
        refute_same value, result
        refute_predicate value, :frozen?
        assert_predicate result, :frozen?
        assert_predicate result.first, :frozen?
      else
        assert_same value, result
      end
    end

    def test_dedup_mode_reuses_equal_values_and_nested_values
      skip "requires native Ractors" unless Internal.native_ractors?

      manager = ModeManager.new(mode: :dedup)
      first = manager.wrap([[+"dedup mode value"]])
      second = manager.wrap([[+"dedup mode value"]])

      assert_same first, second
      assert_same Farce.dedup([+"dedup mode value"]), first.first
      assert_same first, manager.unwrap(first)
      assert Ractor.shareable?(first)
      assert_predicate first, :frozen?
      assert_predicate first.first, :frozen?
    end

    def test_dedup_mode_override_uses_the_default_deduper
      skip "requires native Ractors" unless Internal.native_ractors?

      manager = ModeManager.new(mode: :raise)
      canonical = Farce.dedup([+"dedup override value"])

      assert_same canonical, manager.wrap([+"dedup override value"], mode: :dedup)
      assert_equal :raise, manager.mode
    end

    def test_dedup_mode_preserves_values_on_emulated_ractors
      skip "requires emulated Ractors" if Internal.native_ractors?

      value = [+"dedup emulated value"]

      assert_same value, ModeManager.new(mode: :dedup).wrap(value)
      refute_predicate value, :frozen?
    end

    def test_dedup_mode_keeps_already_shareable_values_unchanged
      manager = ModeManager.new(mode: :dedup)
      canonical = Farce.dedup([:dedup_shareable])
      value = Ractor.make_shareable([:dedup_shareable].freeze)

      refute_same canonical, value
      assert_same value, manager.wrap(value)
    end

    def test_dedup_mode_makes_uncached_objects_shareable
      skip "requires native Ractors" unless Internal.native_ractors?

      manager = ModeManager.new(mode: :dedup)
      value = Struct.new(:contents).new([+"dedup custom value"])
      result = manager.wrap(value)

      assert Ractor.shareable?(result)
      assert_predicate result.contents, :frozen?
      assert_predicate result, :frozen?
    end

    def test_dedup_mode_reuses_values_across_ractors
      skip "requires native Ractors" unless Internal.native_ractors?

      manager = ModeManager.new(mode: :dedup)
      canonical = manager.wrap([+"dedup ractor value"])
      worker = Ractor.new(manager, canonical) do |shared_manager, value|
        shared_manager.wrap([+"dedup ractor value"]).equal?(value)
      end

      assert ractor_value(worker)
    end

    def test_an_explicit_mode_overrides_the_default_without_changing_it
      manager = ModeManager.new(mode: :raise)
      envelope = manager.wrap(Payload.new(:value), mode: :local)

      assert_instance_of Envelope::Local, envelope
      assert_equal :raise, manager.mode
    end

    def test_rejects_an_invalid_mode_override
      manager = ModeManager.new
      error = assert_raises(ArgumentError) { manager.wrap(Payload.new(:value), mode: :invalid) }

      assert_equal "invalid mode: :invalid", error.message
    end

    def test_only_unwraps_envelopes_created_by_the_same_manager
      manager = ModeManager.new
      other = ModeManager.new
      envelope = manager.wrap(Payload.new(:value))
      unmanaged = Envelope::Copy.new(Payload.new(:unmanaged))

      assert_same envelope, other.unwrap(envelope)
      assert_same unmanaged, manager.unwrap(unmanaged)
      assert_equal :value, manager.unwrap(envelope).value
    end

    def test_manager_identity_does_not_use_overridden_equality
      manager = PermissiveEqualityManager.new
      other = PermissiveEqualityManager.new
      envelope = manager.wrap(Payload.new(:value))

      assert_same envelope, other.unwrap(envelope)
      assert_equal :value, manager.unwrap(envelope).value
    end

    def test_copy_envelopes_can_be_automatically_unwrapped_in_another_ractor
      manager = ModeManager.new
      envelope = manager.wrap(Payload.new(:value))
      worker = Ractor.new(manager, envelope) do |shared_manager, shared_envelope|
        value = shared_manager.unwrap(shared_envelope)
        [value.value, shared_manager.unwrap(shared_envelope).equal?(value)].freeze
      end

      assert_equal [:value, true], ractor_value(worker)
    end
  end
end
