# frozen_string_literal: true

return unless RUBY_ENGINE == "ruby"
require_relative "../../setup"

module Farce
  module Internal
    require "objspace"
    require "weakref"

    class TestUnshareable < Test
      include Helpers::InternalTestHelpers

      def test_api_is_owned_by_its_module
        assert_respond_to Unshareable, :pin_to_current_ractor
        assert_respond_to Unshareable, :prevent_copyable
        assert_respond_to Unshareable, :prevent_movable
        refute_respond_to Internal, :pin_to_current_ractor
        refute_respond_to Internal, :prevent_copyable
        refute_respond_to Internal, :prevent_movable
      end

      def test_pin_returns_same_object_and_is_idempotent
        object = Object.new

        assert_same object, Unshareable.pin_to_current_ractor(object)
        assert_same object, Unshareable.pin_to_current_ractor(object)
        assert_empty object.instance_variables
      end

      def test_pinned_built_in_object_remains_mutable
        array = []

        Unshareable.pin_to_current_ractor(array)
        array << :value

        assert_equal [:value], array
      end

      def test_can_apply_guards_inside_another_ractor
        worker = Ractor.new do
          objects = [Object.new, Object.new, Object.new]
          returned = [
            Internal::Unshareable.pin_to_current_ractor(objects[0]),
            Internal::Unshareable.prevent_copyable(objects[1]),
            Internal::Unshareable.prevent_movable(objects[2])
          ]
          [
            returned.zip(objects).all? { |result, object| result.equal?(object) },
            objects.all? { |object| object.instance_variables.empty? },
            objects.none? { |object| Ractor.shareable?(object) }
          ]
        end

        assert_equal [true, true, true], ractor_value(worker)
      end

      def test_pin_prevents_make_shareable
        object = Unshareable.pin_to_current_ractor(Object.new)
        copy_source = Unshareable.pin_to_current_ractor(Object.new)

        assert_raises(Ractor::Error, TypeError) { Ractor.make_shareable(object) }
        refute Ractor.shareable?(object)
        assert_raises(Ractor::Error, TypeError) do
          Ractor.make_shareable(copy_source, copy: true)
        end
        refute_predicate copy_source, :frozen?
        refute Ractor.shareable?(copy_source)
      end

      def test_pin_prevents_copying
        object = Unshareable.pin_to_current_ractor(Object.new)
        receiver = Ractor.new { Ractor.receive }

        assert_raises(Ractor::Error, TypeError) { receiver.send(object) }

        receiver.send(:stop)

        assert_equal :stop, ractor_value(receiver)
        receiver = nil
      ensure
        receiver&.send(:stop)
        ractor_value(receiver) if receiver
      end

      def test_pin_prevents_moving
        child = []
        object = Object.new
        object.instance_variable_set(:@child, child)
        Unshareable.pin_to_current_ractor(object)
        receiver = Ractor.new { Ractor.receive }

        assert_raises(Ractor::Error, TypeError) { receiver.send(object, move: true) }

        if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("4.1")
          assert_same child, object.instance_variable_get(:@child)
          child << :still_here

          assert_equal [:still_here], child
        end

        receiver.send(:stop)

        assert_equal :stop, ractor_value(receiver)
        receiver = nil
      ensure
        receiver&.send(:stop)
        ractor_value(receiver) if receiver
      end

      def test_pin_prevents_port_transfers
        return unless defined?(Ractor::Port)

        port = Ractor::Port.new
        copied = Unshareable.pin_to_current_ractor(Object.new)
        moved = Unshareable.pin_to_current_ractor(Object.new)

        assert_raises(Ractor::Error, TypeError) { port.send(copied) }
        assert_raises(Ractor::Error, TypeError) { port.send(moved, move: true) }
        refute Ractor.shareable?(moved)

        port.send(:stop)

        assert_equal :stop, port.receive
      ensure
        port&.close
      end

      def test_prevent_copyable_rejects_copy_but_allows_move
        copied = Unshareable.prevent_copyable(Object.new)
        copy_receiver = Ractor.new { Ractor.receive }

        assert_raises(Ractor::Error, IOError, TypeError) { copy_receiver.send(copied) }
        copy_receiver.send(:stop)

        assert_equal :stop, ractor_value(copy_receiver)

        moved = Unshareable.prevent_copyable(Object.new)
        move_receiver = Ractor.new do
          object = Ractor.receive
          visible_variables = object.instance_variables
          nested_receiver = Ractor.new { Ractor.receive }
          error = begin
            nested_receiver.send(object)
            nil
          rescue StandardError => e
            e.class.name
          end
          nested_receiver.send(:stop)
          nested_receiver.respond_to?(:value) ? nested_receiver.value : nested_receiver.take
          [visible_variables, error]
        end
        move_receiver.send(moved, move: true)

        visible_variables, error = ractor_value(move_receiver)

        assert_empty visible_variables
        assert_includes ["IOError", "Ractor::Error"], error
        assert_raises(Ractor::MovedError) { moved.class }
      end

      def test_prevent_copyable_markers_close_descriptors_and_follow_owner_lifetime
        return unless descriptor_count = open_file_descriptor_count

        GC.start
        count = 10_000
        objects = Array.new(count) { Unshareable.prevent_copyable(Object.new) }

        GC.start

        assert_equal count, objects.length # Keep every guarded owner alive through this collection.
        markers = objects.values_at(0, count / 2, count - 1).map do |object|
          ObjectSpace.reachable_objects_from(object).find { |value| value.instance_of?(IO) }
        end

        assert_predicate markers, :all?
        assert markers.all?(&:closed?)
        weak_markers = markers.map { |marker| ::WeakRef.new(marker) }

        assert_operator open_file_descriptor_count, :<=, descriptor_count + 2

        markers.clear
        objects.clear
        20.times do
          GC.start
          break if weak_markers.none?(&:weakref_alive?)
        end

        weak_markers.each { |marker| refute_predicate marker, :weakref_alive? }
        assert_operator open_file_descriptor_count, :<=, descriptor_count + 2
      end

      def test_narrower_guards_are_idempotent_and_hidden
        copy_guarded = Object.new
        move_guarded = Object.new

        assert_same copy_guarded, Unshareable.prevent_copyable(copy_guarded)
        assert_same copy_guarded, Unshareable.prevent_copyable(copy_guarded)
        assert_empty copy_guarded.instance_variables
        assert_same move_guarded, Unshareable.prevent_movable(move_guarded)
        assert_same move_guarded, Unshareable.prevent_movable(move_guarded)
        assert_empty move_guarded.instance_variables
      end

      def test_prevent_copyable_shareability_is_version_dependent
        object = Unshareable.prevent_copyable(Object.new)

        if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("4.1")
          assert_raises(Ractor::Error) { Ractor.make_shareable(object) }
          refute Ractor.shareable?(object)
        else
          assert_same object, Ractor.make_shareable(object)
          assert Ractor.shareable?(object)
        end
      end

      def test_prevent_movable_allows_copy_and_the_copy_remains_non_movable
        object = Unshareable.prevent_movable(Object.new)
        receiver = Ractor.new do
          copied = Ractor.receive
          visible_variables = copied.instance_variables
          move_receiver = Ractor.new { Ractor.receive }
          error = begin
            move_receiver.send(copied, move: true)
            nil
          rescue StandardError => e
            e.class.name
          end
          move_receiver.send(:stop)
          move_receiver.respond_to?(:value) ? move_receiver.value : move_receiver.take
          [visible_variables, error]
        end

        receiver.send(object)

        assert_equal [[], "Ractor::Error"], ractor_value(receiver)
        assert_instance_of Object, object
      end

      def test_prevent_movable_does_not_prevent_make_shareable
        object = Unshareable.prevent_movable(Object.new)

        assert_same object, Ractor.make_shareable(object)
        assert Ractor.shareable?(object)
      end

      def test_pin_satisfies_the_narrower_guards_without_extra_markers
        object = Unshareable.pin_to_current_ractor(Object.new)

        assert_same object, Unshareable.prevent_copyable(object)
        assert_same object, Unshareable.prevent_movable(object)
        assert_empty object.instance_variables
      end

      def test_guards_reject_immediate_frozen_and_already_shareable_objects
        methods = %i[pin_to_current_ractor prevent_copyable prevent_movable]

        methods.each do |method|
          assert_raises(TypeError) { Unshareable.public_send(method, 1) }
          assert_raises(FrozenError) { Unshareable.public_send(method, Object.new.freeze) }
          assert_raises(Ractor::IsolationError) { Unshareable.public_send(method, Class.new) }
        end
      end
    end
  end
end
