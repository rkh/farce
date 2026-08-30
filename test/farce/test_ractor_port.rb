# frozen_string_literal: true

require_relative "../setup"

require "farce"

module Farce
  class TestRactorPort < Test
    Port = Ractor::Port

    def test_farce_port_is_a_ractor_port_subclass
      assert_operator Farce::Port, :<, Port
    end

    def test_port_sends_and_receives_values
      port = Port.new

      assert_same port, port.send(:message)
      assert_equal :message, port.receive
    end

    def test_left_shift_sends_values
      port = Port.new

      assert_same port, port << :message
      assert_equal :message, port.receive
    end

    def test_close_closes_port
      port = Port.new

      assert_same port, port.close
      wait_for_port_to_close(port)

      assert_predicate port, :closed?
    end

    def test_send_to_closed_port_raises_closed_error
      port = Port.new
      port.close
      wait_for_port_to_close(port)

      assert_raises(Ractor::ClosedError) { port.send(:message) }
    end

    def test_inspect_identifies_port
      assert_match(/\A#<.*Port.* id:/, Port.new.inspect)
    end

    def test_new_returns_existing_fallback_port
      return unless cruby_34_fallback?
      port = Port.new

      assert_same port, Port.new(port)
    end

    def test_new_wraps_ractor_in_fallback_port
      return unless cruby_34_fallback?
      ractor = ::Ractor.new { ::Ractor.receive }
      port = Port.new(ractor)

      assert_match(/\A#<Farce::Ractor::Port to:#\d+ id:\d+>\z/, port.inspect)
      assert_same port, port.send(:message)
      assert_equal :message, ractor_value(ractor)
    end

    def test_new_rejects_invalid_argument
      return unless cruby_34_fallback?
      error = assert_raises(ArgumentError) { Port.new(:invalid) }

      assert_equal "wrong number of arguments (given 1, expected 0)", error.message
    end

    def test_receive_timeout
      return if RUBY_ENGINE != "ruby" || RUBY_VERSION[0, 3] == "4.0"
      port = Port.new
      Timeout.timeout(0.1) { port.receive(timeout: 0.01) }
    end

    def test_fallback_port_can_only_receive_from_owner_ractor
      return unless cruby_34_fallback?
      port = Port.new
      ractor = ::Ractor.new(port) do |remote_port|
        remote_port.receive
      rescue ::Ractor::Error => e
        [e.class.name, e.message]
      end

      assert_equal ["Ractor::Error", "only allowed from the creator ::Ractor of this port"], ractor_value(ractor)
    end

    def test_fallback_uninitialized_inspect_falls_back
      return unless cruby_34_fallback?

      assert_match(/\A#<Farce::Internal::Port:/, Port.allocate.inspect)
    end

    def test_does_not_get_automatically_included_in_ractor
      refute defined?(::Ractor::Port) if cruby_34_fallback?
    end

    private

    def cruby_34_fallback?
      RUBY_ENGINE == "ruby" && RUBY_VERSION < "4"
    end

    def ractor_value(ractor) = ractor.respond_to?(:value) ? ractor.value : ractor.take

    def wait_for_port_to_close(port)
      100.times do
        return if port.closed?

        sleep 0.001
      end
    end
  end
end
