# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "pp"

module Farce
  class TestStrictPort < Test
    include Helpers::InternalTestHelpers

    def setup
      @port = Strict::Port.new
    end

    def teardown
      @port.close unless @port.closed?
    end

    def test_initialization_and_interface
      assert_instance_of Strict::Port, @port
      assert_kind_of Abstract::Port, @port
      assert_equal Internal::Port, Strict::Port.superclass
      assert_predicate @port, :owned?
      assert_predicate @port, :ractor_shareable?
      assert Ractor.shareable?(@port)
      refute_predicate @port, :frozen?
      refute_predicate @port, :closed?
      refute_respond_to @port, :mode
      refute_respond_to @port, :auto_local?
      assert_raises(ArgumentError) { Strict::Port.new(@port) }
    end

    def test_transfer_options_are_rejected
      [{ mode: :copy }, { move: true }, { auto_local: true }].each do |option|
        assert_raises(ArgumentError) { Strict::Port.new(**option) }
        %i[send push <<].each do |method|
          assert_raises(ArgumentError) { @port.public_send(method, :value, **option) }
        end
      end

      assert_nil @port.receive(timeout: 0)
    end

    def test_shareable_messages_preserve_identity_and_order
      messages = [nil, false, true, 42, :ready, "frozen", [:nested, "value"].freeze, Strict::Queue.new]

      messages.each { |message| assert_same @port, @port.send(message) }
      results = messages.map { @port.receive(timeout: 1) }
      messages.zip(results).each do |message, result|
        message.nil? ? assert_nil(result) : assert_same(message, result)
      end
    end

    def test_envelopes_are_returned_unopened
      envelope = Envelope.new(ModePayload.new(:value), mode: :local)

      assert_same @port, @port.send(envelope)
      assert_same envelope, @port.receive(timeout: 1)
    end

    def test_rejects_unshareable_messages_without_changing_them
      message = ModePayload.new(:original)
      %i[send push <<].each do |method|
        assert_raises(Ractor::IsolationError) { @port.public_send(method, message) }
        assert_equal :original, message.value
        refute_predicate message, :frozen?
        assert_nil @port.pop(timeout: 0)
      end
      message.value = :changed

      assert_equal :changed, message.value
    end

    def test_rejects_mutable_and_shallow_frozen_messages_on_cruby
      return unless Internal.native_ractors?
      mutable = +"mutable"

      [Object.new, mutable, [mutable].freeze].each do |message|
        assert_raises(Ractor::IsolationError) { @port.send(message) }
      end
      refute_predicate mutable, :frozen?
      assert_nil @port.receive(timeout: 0)
    end

    def test_timeouts_and_delegates
      assert_nil @port.receive(timeout: 0)
      assert_nil @port.pop(timeout: 0.001)
      assert_same @port, @port << :first
      assert_same @port, @port.push(nil)
      assert_equal :first, @port.pop(timeout: nil)
      assert_nil @port.pop(timeout: 1)
      @port.send(false)

      assert_same false, @port.receive
    end

    def test_close_and_closed_errors
      assert_same @port, @port.close
      assert_predicate @port, :closed?
      assert_raises(Ractor::ClosedError) { @port.send(:message) }
      assert_raises(Ractor::ClosedError) { @port.push(:message) }
      assert_raises(Ractor::ClosedError) { @port << :message }
      assert_raises(Ractor::ClosedError) { @port.receive }
      assert_raises(Ractor::ClosedError) { @port.pop(timeout: 0) }
    end

    def test_remote_sends_preserve_identity_and_report_ownership
      message = [:shared].freeze
      worker = Ractor.new(@port, message) do |port, value|
        port.push(value)
        port.owned?
      end

      assert_same message, @port.receive(timeout: 5)
      refute ractor_value(worker)
      assert_predicate @port, :owned?
    end

    def test_remote_sender_cannot_receive_or_close_on_cruby
      return unless Internal.native_ractors?
      worker = Ractor.new(@port) do |port|
        %i[receive close].map do |method|
          port.public_send(method)
          false
        rescue Ractor::Error
          true
        end.freeze
      end

      assert_equal [true, true], ractor_value(worker)
      refute_predicate @port, :closed?
    end

    def test_inspect_and_pretty_print
      assert_match(/\A#<Farce::Strict::Port (?:to:#\d+ )?id:\d+>\z/, @port.inspect)
      assert_equal @port.inspect, @port.pretty_inspect.chomp
    end
  end
end
