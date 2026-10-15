# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "pp"

module Farce
  class TestNullPort < Test
    using Backports

    def test_type_and_shareability
      assert_kind_of Ractor::Port, NULL_PORT
      assert Ractor.shareable?(NULL_PORT)
      refute_predicate NULL_PORT, :closed?
    end

    def test_send_discards_messages_and_returns_self
      [nil, false, true, 42, :message, +"mutable", Object.new, -> {}].each do |message|
        assert_same NULL_PORT, NULL_PORT.send(message)
      end
      refute_predicate NULL_PORT, :closed?
    end

    def test_send_does_not_copy_or_freeze_mutable_messages
      message = [+"mutable"]

      assert_same NULL_PORT, NULL_PORT.send(message)
      assert_same NULL_PORT, NULL_PORT.send(message, move: false)
      message.first << " value"
      message << :still_available

      assert_equal ["mutable value", :still_available], message
    end

    def test_send_can_move_unshareable_messages
      message = [+"moved"]

      assert_same NULL_PORT, NULL_PORT.send(message, move: true)
      if Ractor.builtin?
        assert_raises(Ractor::MovedError) { message.size }
      else
        assert_equal ["moved"], message
      end

      refute_predicate NULL_PORT, :closed?
    end

    def test_moving_shareable_messages_preserves_them
      message = [:shared].freeze

      assert_same NULL_PORT, NULL_PORT.send(message, move: true)
      assert_equal [:shared], message
    end

    def test_receive_and_close_are_rejected
      assert_raises(Ractor::Error) { NULL_PORT.receive }
      assert_raises(Ractor::Error) { NULL_PORT.close }
      refute_predicate NULL_PORT, :closed?
      assert_same NULL_PORT, NULL_PORT.send(:still_open)
    end

    def test_can_be_used_from_another_ractor
      worker = Ractor.new(NULL_PORT) do |port|
        sent = port.send(:message).equal?(port)
        errors = %i[receive close].map do |method|
          port.public_send(method)
          false
        rescue Ractor::Error
          true
        end
        [port.equal?(NULL_PORT), sent, port.closed?, *errors].freeze
      end

      result = worker.respond_to?(:value) ? worker.value : worker.take

      assert_equal [true, true, false, true, true], result
      refute_predicate NULL_PORT, :closed?
    end

    def test_can_receive_ractor_exit_notifications
      worker = Ractor.new { Ractor.receive }

      assert worker.monitor(NULL_PORT)
      worker.send(:done)
      result = worker.respond_to?(:value) ? worker.value : worker.take

      assert_equal :done, result
      refute worker.monitor(NULL_PORT)
      assert_same worker, worker.unmonitor(NULL_PORT)
      refute_predicate NULL_PORT, :closed?
    ensure
      worker&.send(:done) if result.nil?
    end

    def test_inspect_and_pretty_print
      assert_equal "Farce::NULL_PORT", NULL_PORT.inspect
      assert_equal "Farce::NULL_PORT\n", NULL_PORT.pretty_inspect
    end
  end
end
