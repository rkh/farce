# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestUnshareable < Test
    include Helpers::InternalTestHelpers

    class Movable
      include Unshareable::Movable
    end

    class Copyable
      include Unshareable::Copyable
    end

    class Transferable
      include Unshareable::Movable
      include Unshareable::Copyable
    end

    def test_movable_mixin_rejects_copying
      object = Movable.new

      refute_respond_to object, :freeze
      refute_predicate object, :ractor_shareable?
      return unless Helpers::Internal.native_ractors?

      receiver = Ractor.new do
        Ractor.receive
        :received
      end

      assert_raises(Ractor::Error, TypeError, IOError) { receiver.send(object) }
      receiver.send(object, move: true)

      assert_equal :received, ractor_value(receiver)
      receiver = nil
    ensure
      receiver&.send(:stop)
      ractor_value(receiver) if receiver
    end

    def test_copyable_mixin_rejects_moving
      object = Copyable.new

      refute_respond_to object, :freeze
      refute_predicate object, :ractor_shareable?
      return unless Helpers::Internal.native_ractors?

      receiver = Ractor.new do
        Ractor.receive
        :received
      end

      assert_raises(Ractor::Error, TypeError) { receiver.send(object, move: true) }
      receiver.send(object)

      assert_equal :received, ractor_value(receiver)
      receiver = nil
    ensure
      receiver&.send(:stop)
      ractor_value(receiver) if receiver
    end

    def test_both_mixins_allow_copying_and_moving
      [false, true].each do |move|
        object = Transferable.new

        refute_respond_to object, :freeze
        refute_predicate object, :ractor_shareable?

        receiver = Ractor.new do
          Ractor.receive
          :received
        end
        receiver.send(object, move:)

        assert_equal :received, ractor_value(receiver)
      end
    end
  end
end
