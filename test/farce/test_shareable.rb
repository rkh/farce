# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestShareable < Test
    include Helpers::InternalTestHelpers

    class DelegatedValue
      include Internal::Copyable
      include Shareable::Delegated

      def initialize(value = 1)
        @storage = Internal::Counter.new(value)
        super()
      end

      def value = @storage.value
      def increment = @storage.increment

      private

      def freeze_backend = @storage

      def initialize_copy(other)
        super
        @storage = Internal::Counter.new(other.value)
      end
    end

    class TrackedValue
      include Internal::Copyable
      include Shareable::Tracked

      def initialize(value = 1)
        @storage = Internal::Counter.new(value)
        super()
      end

      def value = @storage.value

      def increment
        check_frozen!
        @storage.increment
      end

      private

      def initialize_copy(other)
        super
        @storage = Internal::Counter.new(other.value)
      end
    end

    class Service
      include Shareable::Unfreezable
    end

    class ImmutableValue
      include Shareable::Immutable
    end

    class NativeValue < Internal::Counter
      include Shareable::Native
    end

    def test_each_policy_includes_shareable
      [DelegatedValue, TrackedValue, Service, ImmutableValue, NativeValue].each do |type|
        value = type.new

        assert_kind_of Shareable, value
        assert_predicate value, :ractor_shareable?
        assert Ractor.shareable?(value)
      end
    end

    def test_immutable_policy_freezes_during_initialization
      assert_predicate ImmutableValue.new, :frozen?
    end

    def test_native_policy_preserves_native_frozen_state
      value = NativeValue.new

      refute_predicate value, :frozen?
      value.increment

      assert_equal 1, value.value
      assert_same value, value.freeze
      assert_raises(FrozenError) { value.increment }
    end

    def test_logical_freeze_is_separate_from_structural_publication
      [DelegatedValue, TrackedValue].each do |type|
        value = type.new

        refute_predicate value, :frozen?
        assert Object.instance_method(:frozen?).bind_call(value)
        assert Ractor.shareable?(value)
        value.increment

        assert_equal 2, value.value
        assert_same value, value.freeze
        assert_predicate value, :frozen?
        assert_raises(FrozenError) { value.increment }
        assert_equal 2, value.value
      end
    end

    def test_publication_does_not_call_rejected_public_freeze
      service = Service.new

      refute_predicate service, :frozen?
      assert Object.instance_method(:frozen?).bind_call(service)
      assert Ractor.shareable?(service)
      assert_raises(TypeError) { service.freeze }
    end

    def test_copy_state_is_independent_for_both_policies
      [DelegatedValue, TrackedValue].each do |type|
        [false, true].each do |frozen|
          original = type.new
          original.freeze if frozen
          copies = [original.dup, original.clone, original.clone(freeze: false), original.clone(freeze: true)]

          assert_equal [false, frozen, false, true], copies.map(&:frozen?)
          copies.each do |copy|
            refute_same original, copy
            assert Object.instance_method(:frozen?).bind_call(copy)
            assert Ractor.shareable?(copy)
          end
          copies[0].increment

          assert_equal 1, original.value
          assert_equal [2, 1, 1, 1], copies.map(&:value)
          copies[0].freeze

          assert_equal frozen, original.frozen?
          refute_predicate copies[2], :frozen?
        end
      end
    end

    def test_tracked_error_identifies_public_receiver
      value = TrackedValue.new.freeze
      error = assert_raises(FrozenError) { value.increment }

      assert_same value, error.receiver
    end

    def test_policies_can_construct_and_copy_inside_worker_ractor
      return unless Internal.native_ractors?

      worker = Ractor.new do
        [DelegatedValue, TrackedValue].map do |type|
          value = type.new
          value.increment
          copy = value.freeze.clone(freeze: false)
          copy.increment
          [value.value, value.frozen?, copy.value, copy.frozen?, ::Ractor.shareable?(copy)].freeze
        end.freeze
      end

      assert_equal [[2, true, 3, false, true], [2, true, 3, false, true]], ractor_value(worker)
    end
  end
end
