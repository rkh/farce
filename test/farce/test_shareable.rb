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

    def test_object_id_does_not_change_published_facade_storage
      return unless RUBY_ENGINE == "ruby" && RUBY_VERSION >= "4.1"

      require "objspace"
      require "json"
      [DelegatedValue, TrackedValue, Service, ImmutableValue].each do |type|
        value = type.new
        before = JSON.parse(ObjectSpace.dump(value))
        identity = BasicObject.instance_method(:__id__).bind_call(value)
        after = JSON.parse(ObjectSpace.dump(value))

        assert_equal identity, before.dig("flags", "object_id"), type.name
        assert_equal before["shape_id"], after["shape_id"], type.name
        assert_equal before["ivars"], after["ivars"], type.name
        assert_equal identity, value.object_id
        [value.dup, value.clone].each do |copy|
          refute_equal identity, copy.object_id
          storage = JSON.parse(ObjectSpace.dump(copy))

          assert_equal copy.object_id, storage.dig("flags", "object_id"), type.name
          assert_equal after["ivars"], storage["ivars"], type.name
        end
      end
    end

    def test_identity_is_prepared_before_initialization
      return unless RUBY_ENGINE == "ruby" && RUBY_VERSION >= "4.1"

      require "objspace"
      require "json"
      type = Class.new(ImmutableValue) do
        attr_reader :initial_identity, :value

        def initialize(value, increment:, &block)
          @initial_identity = JSON.parse(ObjectSpace.dump(self)).dig("flags", "object_id")
          @value = block.call(value + increment)
          super()
        end
      end
      value = type.new(2, increment: 3) { it * 2 }

      assert_equal value.object_id, value.initial_identity
      assert_equal 10, value.value
      assert_equal [%i[req value], %i[keyreq increment], %i[block block]],
        type.instance_method(:initialize).parameters
    end

    def test_policy_preserves_an_existing_custom_constructor
      type = Class.new do
        def self.new(value) = super().tap { raise "expected nil" unless value.nil? }

        include Shareable::Immutable
      end

      assert_raises(ArgumentError) { type.new }
      assert Ractor.shareable?(type.new(nil))
      assert_raises(RuntimeError) { type.new(1) }
    end

    def test_policy_preserves_constructor_visibility
      private_type = Class.new do
        private_class_method :new
        include Shareable::Immutable
      end
      undefined_type = Class.new do
        singleton_class.undef_method(:new)
        include Shareable::Immutable
      end

      assert_raises(NoMethodError) { private_type.new }
      assert_raises(NoMethodError) { undefined_type.new }
    end

    def test_policy_can_be_added_to_a_singleton_class
      value = Object.new
      value.singleton_class.include(Shareable::Immutable)
      Internal::Freeze.publish(value)

      assert Ractor.shareable?(value)
      assert_predicate value, :frozen?
    end

    def test_policy_can_be_included_in_a_worker_class
      worker = Ractor.new do
        type = Class.new do
          include Shareable::Immutable

          attr_reader :value

          def initialize
            @value = 1
            super
          end
        end
        value = type.new
        [value.value, value.frozen?, Farce::Ractor.shareable?(value)]
      end

      assert_equal [1, true, true], ractor_value(worker)
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
