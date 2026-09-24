# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "setup"

class TestDnsServer < Test
  def test_retries_unavailable_ports_and_closes_failed_socket_pairs
    check_binding("Errno::EACCES", failures: 2, attempts: 3)
    check_binding("Errno::EADDRINUSE", failures: 2, attempts: 3)
  end

  def test_stops_after_ten_unavailable_ports
    check_binding("Errno::EACCES", failures: 10, attempts: 10)
  end

  def test_other_socket_errors_are_not_retried
    check_binding("Errno::EMFILE", failures: 1, attempts: 1)
  end

  private

  def check_binding(error_class, failures:, attempts:)
    output, error, status = ruby_isolated(<<~RUBY)
      require "helpers/dns_server"
      $sockets = []
      $attempts = 0
      $tracking = true
      UDPSocket.prepend(Module.new do
        def bind(*)
          return super unless $tracking
          $sockets << self
          $attempts += 1
          raise #{error_class} if $attempts <= #{failures}
          super
        end
      end)
      TCPServer.singleton_class.prepend(Module.new do
        def new(*)
          super.tap { |socket| $sockets << socket }
        end
      end)

      server = nil
      begin
        server = Helpers::DnsServer.new(truncate_udp: true)
        $tracking = false
        abort "unexpected success" if #{failures} >= #{attempts}
        abort "failed sockets leaked" unless $sockets[0...-2].all?(&:closed?)
        dns = Resolv::DNS.new(server.config)
        dns.timeouts = 1
        addresses = dns.getaddresses("answer.test").map(&:to_s).sort
        abort "DNS fallback failed" unless addresses == %w[192.0.2.42 2001:db8::42]
      rescue #{error_class}
        raise if #{failures} < #{attempts}
      ensure
        dns&.close
        server&.close
      end
      abort "wrong number of attempts" unless $attempts == #{attempts}
      abort "sockets leaked" unless $sockets.all?(&:closed?)
      puts "ok"
    RUBY

    assert_predicate status, :success?, error
    assert_equal "ok\n", output
  end
end
