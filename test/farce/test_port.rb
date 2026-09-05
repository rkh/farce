# frozen_string_literal: true

require_relative "../setup"
require "pp"

module Farce
  class TestPort < Test
    include Helpers::InternalTestHelpers

    def test_initialization_hierarchy_and_defaults
      port = Port.new

      assert_equal Internal::Port, Port.superclass
      assert_instance_of Port, port
      assert_equal :copy, port.mode
      refute_predicate port, :auto_local?
      assert_predicate port, :owned?
      assert_predicate port, :frozen?
      assert_predicate port, :ractor_shareable?
      assert Ractor.shareable?(port)
    end

    def test_mode_and_auto_local_specializations
      ModeManager::MODES.each do |mode|
        normal = Port[mode]
        local  = Port[mode, auto_local: true]

        assert_same normal, Port[mode]
        assert_same local, Port[mode, auto_local: true]
        assert_equal mode, normal.mode
        assert_equal mode, local.mode
        refute_predicate normal, :auto_local?
        assert_predicate local, :auto_local?
        assert_operator local, :<, normal
        mode == :copy ? assert_same(Port, normal) : assert_operator(normal, :<, Port)

        normal_port = Port.new(mode:)
        local_port  = Port.new(mode:, auto_local: true)

        assert_instance_of normal, normal_port
        assert_instance_of local, local_port
        assert_equal mode, normal_port.mode
        assert_equal mode, local_port.mode
        refute_predicate normal_port, :auto_local?
        assert_predicate local_port, :auto_local?
      end
    end

    def test_auto_local_can_be_enabled_without_repeating_the_default_mode
      port = Port.new(auto_local: true)

      assert_equal :copy, port.mode
      assert_predicate port, :auto_local?
      assert_instance_of Port[:copy, auto_local: true], port
    end

    def test_rejects_invalid_or_mismatched_specializations
      error = assert_raises(ArgumentError) { Port[:invalid] }
      assert_equal "invalid mode: :invalid", error.message

      error = assert_raises(ArgumentError) { Port.new(mode: :invalid) }
      assert_equal "invalid mode: :invalid", error.message

      move_port = Port[:move]

      assert_same move_port, move_port[:move]

      error = assert_raises(ArgumentError) { move_port[:copy] }
      assert_equal "mode mismatch: :copy vs :move", error.message

      automatic = Port[:move, auto_local: true]

      assert_same automatic, automatic[:move, auto_local: true]

      error = assert_raises(ArgumentError) { automatic[:move, auto_local: false] }
      assert_equal "auto_local mismatch: false vs true", error.message
    end

    def test_copy_mode_sends_a_snapshot_and_receive_automatically_unwraps_it
      return unless Internal.native_ractors?
      port = Port.new
      source = ModePayload.new(:original)

      assert_same port, port.send(source)

      source.value = :changed
      result = port.receive

      refute_same source, result
      assert_equal :original, result.value
    end

    def test_local_mode_preserves_identity
      port = Port.new(mode: :local)
      value = ModePayload.new(:value)

      assert_same port, port.send(value)
      assert_same value, port.receive
      assert_equal :local, port.mode
    end

    def test_explicit_mode_overrides_the_default_without_changing_it
      return unless Internal.native_ractors?
      port = Port.new(mode: :raise)
      source = ModePayload.new(:original)

      assert_same port, port.send(source, mode: :copy)

      source.value = :changed
      result = port.receive

      refute_same source, result
      assert_equal :original, result.value
      assert_equal :raise, port.mode

      error = assert_raises(Ractor::IsolationError) do
        port.send(ModePayload.new(:rejected))
      end
      assert_match(/value is not Ractor-shareable/, error.message)
    end

    def test_auto_local_prefers_identity_for_sends_from_the_owner
      port = Port.new(mode: :raise, auto_local: true)
      automatic = ModePayload.new(:automatic)

      assert_same port, port.send(automatic)
      assert_same automatic, port.receive

      explicit = ModePayload.new(:explicit)

      assert_same port, port.send(explicit, mode: :copy, auto_local: true)
      assert_same explicit, port.receive
    end

    def test_auto_local_can_be_disabled_for_an_individual_send
      return unless Internal.native_ractors?
      port = Port.new(auto_local: true)
      source = ModePayload.new(:original)

      assert_same port, port.send(source, auto_local: false)

      source.value = :changed
      result = port.receive

      refute_same source, result
      assert_equal :original, result.value
    end

    def test_move_flag_selects_move_or_copy_mode
      return unless Internal.native_ractors?
      port = Port.new(mode: :move)
      copied = ModePayload.new(:copied)

      assert_same port, port.send(copied, move: false)

      copied.value = :changed
      result = port.receive

      refute_same copied, result
      assert_equal :copied, result.value

      moved = ModePayload.new(:moved)

      assert_same port, port.send(moved, move: true)
      assert_equal :moved, port.receive.value

      error = assert_raises(ArgumentError) { port.send(Object.new, move: :invalid) }
      assert_equal "invalid move: :invalid", error.message
    end

    def test_send_and_receive_aliases
      port = Port.new

      assert_same port, port << :first
      assert_same port, port.push(nil)
      assert_equal :first, port.pop
      assert_nil port.receive
    end

    def test_receive_forwards_timeouts_and_preserves_local_values
      if RUBY_ENGINE == "ruby" && RUBY_VERSION.start_with?("4.0.")
        skip "CRuby 4.0's timeout selector is not implemented"
      end
      port = Port.new(mode: :local)

      assert_nil port.receive(timeout: 0)
      value = ModePayload.new(:value)
      port.send(value)

      assert_same value, port.pop(timeout: 1)
      port.send(nil)

      assert_nil port.receive(timeout: nil)
      assert_nil port.pop(timeout: 0.001)
    end

    def test_receive_with_an_explicit_nil_timeout
      port = Port.new(mode: :local)
      value = ModePayload.new(:value)
      port.send(value)

      assert_same value, port.receive(timeout: nil)
    end

    def test_send_to_a_closed_port_does_not_consume_the_value
      port = Port.new(mode: :move)
      port.close
      value = ModePayload.new(:available)

      assert_raises(Ractor::ClosedError) { port.send(value) }
      refute_operator Ractor::MovedObject, :===, value
      assert_equal :available, value.value
    end

    def test_ownership_is_local_to_the_creating_ractor
      port = Port.new(auto_local: true)
      worker = Ractor.new(port) do |remote_port|
        [remote_port.owned?, remote_port.mode, remote_port.auto_local?].freeze
      end

      assert_predicate port, :owned?
      assert_equal [false, :copy, true], ractor_value(worker)
    end

    def test_remote_sends_do_not_apply_auto_local
      return unless Internal.native_ractors?
      port = Port.new(auto_local: true)
      worker = Ractor.new(port) do |remote_port|
        value = Helpers::ModePayload.new(:original)
        remote_port.send(value)
        value.value = :changed
      end

      assert_equal :changed, ractor_value(worker)

      result = port.receive

      assert_instance_of ModePayload, result
      assert_equal :original, result.value
    end

    def test_inspect_and_pretty_print_include_the_mode
      port = Port.new(mode: :shareable_copy, auto_local: true)

      assert_match(/\A#<Farce::Port mode:shareable_copy (?:to:#\d+ )?id:\d+>\z/, port.inspect)
      assert_equal port.inspect, port.pretty_inspect.chomp
    end
  end
end
