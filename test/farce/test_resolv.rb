# frozen_string_literal: true
require_relative "../setup"

module Farce
  class TestResolv < Test
    def setup
      @server = Helpers::DnsServer.new
      @previous = Resolv.resolver
      @dns = Resolv::DNS.new(@server.config)
      @dns.timeouts = 1
      Internal::Storage[Resolv] = Resolv.new([@dns])
    end

    def teardown
      Internal::Storage[Resolv] = @previous
      @dns.close
      @server.close
    end

    def test_forward_reverse_and_missing_names
      assert_equal %w[192.0.2.42 2001:db8::42], Resolv.getaddresses("answer.test").sort
      assert_includes %w[192.0.2.42 2001:db8::42], Resolv.getaddress("answer.test")
      yielded = []
      Resolv.each_address("answer.test") { yielded << it }

      assert_equal %w[192.0.2.42 2001:db8::42], yielded.sort
      assert_equal ["answer.test"], Resolv.getnames("192.0.2.42")
      assert_equal "answer.test", Resolv.getname("192.0.2.42")
      yielded = []
      Resolv.each_name("192.0.2.42") { yielded << it }

      assert_equal ["answer.test"], yielded
      assert_empty Resolv.getaddresses("missing.test")
      assert_raises(::Resolv::ResolvError) { Resolv.getaddress("missing.test") }
      refute_empty @server.requests
    end

    def test_standard_resolver_instances_use_the_patch
      assert_equal ::Resolv::DNS, Resolv::DNS.superclass
      assert_same ::Resolv::DNS::Message, Resolv::DNS::Message
      assert_instance_of Resolv::DNS, Resolv.new.instance_variable_get(:@resolvers).last
      assert_equal %w[192.0.2.42 2001:db8::42], ::Resolv.new(@server.config).getaddresses("answer.test").sort
      assert_equal %w[192.0.2.42 2001:db8::42], Resolv.new(@server.config).getaddresses("answer.test").sort
    end

    def test_request_identifiers_are_reserved_across_threads_and_released
      identifiers = 4.times.map do
        Thread.new { 100.times.map { Resolv::DNS.allocate_request_id("answer.test", 53) } }
      end.flat_map(&:value)

      assert_equal 400, identifiers.uniq.size
      assert(identifiers.all? { it.between?(0, 65_535) })
      identifiers.each { Resolv::DNS.free_request_id("answer.test", 53, it) }
      _, requests = Internal::Storage[Resolv::DNS]

      refute requests.key?(["answer.test", 53])
    ensure
      identifiers&.each { Resolv::DNS.free_request_id("answer.test", 53, it) }
    end

    def test_multiple_nameservers_use_unconnected_udp
      nameserver_port = [["127.0.0.1", @server.port], ["127.0.0.1", @server.port]]
      dns = Resolv::DNS.new(@server.config.merge(nameserver_port:))
      dns.timeouts = 1

      assert_equal %w[192.0.2.42 2001:db8::42], dns.getaddresses("answer.test").map(&:to_s).sort
    ensure
      dns&.close
    end

    def test_truncated_udp_retries_over_tcp_in_another_ractor
      server = Helpers::DnsServer.new(truncate_udp: true)
      task = Ractor.new(server.port) do |port|
        dns = Resolv::DNS.new(nameserver_port: [["127.0.0.1", port]], search: [], ndots: 1, use_ipv6: true)
        dns.timeouts = 1
        begin
          dns.getaddresses("answer.test").map(&:to_s).sort
        ensure
          dns.close
        end
      end
      addresses = task.respond_to?(:value) ? task.value : task.take

      assert_equal %w[192.0.2.42 2001:db8::42], addresses
      assert_equal 4, server.requests.size
    ensure
      server&.close
    end

    def test_tcp_retry_replaces_a_closed_connection
      return unless ::Resolv::DNS::Requester::TCP.method_defined?(:reusable?)
      begin
        server = Helpers::DnsServer.new(truncate_udp: true, drop_tcp_first: true)
        dns = Resolv::DNS.new(server.config)
        dns.timeouts = [0.1, 1]

        assert_equal %w[192.0.2.42 2001:db8::42], dns.getaddresses("answer.test").map(&:to_s).sort
      ensure
        dns&.close
        server&.close
      end
    end

    def test_message_identifiers_are_atomic_and_preserve_explicit_ids
      identifiers = 4.times.map do
        Thread.new { 100.times.map { Resolv::DNS::Message.new.id } }
      end.flat_map(&:value)

      assert_equal 400, identifiers.uniq.size
      assert(identifiers.all? { it.between?(0, 65_535) })
      assert_equal 17, Resolv::DNS::Message.new(17).id
    end

    def test_resolver_and_dns_work_in_another_ractor
      main = Resolv.resolver
      task = Ractor.new(@server.port) do |port|
        resolver = Resolv.resolver
        same = Thread.new { Resolv.resolver.equal?(resolver) }.value
        dns = Resolv::DNS.new(nameserver_port: [["127.0.0.1", port]], search: [], ndots: 1, use_ipv6: true)
        dns.timeouts = 1
        Internal::Storage[Resolv] = Resolv.new([dns])
        addresses = Resolv.getaddresses("answer.test").sort
        names = Resolv.getnames("192.0.2.42")
        id = Resolv::DNS::Message.new.id
        dns.close
        [resolver.object_id, same, addresses, names, id]
      end
      id, same, addresses, names, message_id = task.respond_to?(:value) ? task.value : task.take

      refute_equal main.object_id, id
      assert same
      assert_same main, Resolv.resolver
      assert_equal %w[192.0.2.42 2001:db8::42], addresses
      assert_equal ["answer.test"], names
      assert message_id.between?(0, 65_535)
    end
  end
end
