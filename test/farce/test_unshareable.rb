# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestUnshareable < Test
    include Helpers::InternalTestHelpers

    class Pinned
      include Unshareable
    end

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

    def test_freezing_preserves_unshareability_and_reports_the_owner_class
      [Pinned, Movable, Copyable, Transferable].each do |klass|
        [false, true].each do |frozen|
          object = klass.new
          assert_same object, object.freeze if frozen

          refute_predicate object, :ractor_shareable?
          next unless Helpers::Internal.native_ractors?

          error = assert_raises(Ractor::Error) { Ractor.make_shareable(object) }

          assert_includes error.message, klass.name
          assert_predicate object, :frozen?
          refute Ractor.shareable?(object)
        end
      end
    end

    def test_plain_mixin_rejects_copying_and_moving_after_freezing
      object = Pinned.new.freeze
      return unless Helpers::Internal.native_ractors?

      receiver = Ractor.new { Ractor.receive }

      assert_raises(Ractor::Error, TypeError) { receiver.send(object) }
      assert_raises(Ractor::Error, TypeError) { receiver.send(object, move: true) }
      receiver.send(:stop)

      assert_equal :stop, ractor_value(receiver)
      receiver = nil
    ensure
      receiver&.send(:stop)
      ractor_value(receiver) if receiver
    end

    def test_movable_mixin_rejects_copying
      object = Movable.new.freeze

      assert_predicate object, :frozen?
      refute_predicate object, :ractor_shareable?
      return unless Helpers::Internal.native_ractors?
      assert_raises(Ractor::Error) { Ractor.make_shareable(object) }

      receiver = Ractor.new do
        received = Ractor.receive
        error = begin
          Ractor.make_shareable(received)
        rescue Ractor::Error => e
          e.message
        end
        [received.frozen?, Ractor.shareable?(received), error]
      end

      assert_raises(Ractor::Error, TypeError, IOError) { receiver.send(object) }
      receiver.send(object, move: true)

      frozen, shareable, message = ractor_value(receiver)
      receiver = nil

      assert frozen
      refute shareable
      assert_includes message, Movable.name
    ensure
      receiver&.send(:stop)
      ractor_value(receiver) if receiver
    end

    def test_copyable_mixin_rejects_moving
      object = Copyable.new.freeze

      assert_predicate object, :frozen?
      refute_predicate object, :ractor_shareable?
      return unless Helpers::Internal.native_ractors?
      assert_raises(Ractor::Error) { Ractor.make_shareable(object) }

      receiver = Ractor.new do
        received = Ractor.receive
        error = begin
          Ractor.make_shareable(received)
        rescue Ractor::Error => e
          e.message
        end
        [received.frozen?, Ractor.shareable?(received), error]
      end

      assert_raises(Ractor::Error, TypeError) { receiver.send(object, move: true) }
      receiver.send(object)

      frozen, shareable, message = ractor_value(receiver)
      receiver = nil

      assert frozen
      refute shareable
      assert_includes message, Copyable.name
    ensure
      receiver&.send(:stop)
      ractor_value(receiver) if receiver
    end

    def test_both_mixins_allow_copying_and_moving
      [false, true].each do |move|
        object = Transferable.new.freeze

        assert_predicate object, :frozen?
        refute_predicate object, :ractor_shareable?
        assert_raises(Ractor::Error) { Ractor.make_shareable(object) } if Helpers::Internal.native_ractors?

        receiver = Ractor.new do
          received = Ractor.receive
          error = begin
            Ractor.make_shareable(received) if Internal.native_ractors?
          rescue Ractor::Error => e
            e.message
          end
          [received.frozen?, received.ractor_shareable?, error]
        end
        receiver.send(object, move:)

        frozen, shareable, message = ractor_value(receiver)

        assert frozen
        refute shareable
        assert_includes message, Transferable.name if Helpers::Internal.native_ractors?
      end
    end
  end
end
