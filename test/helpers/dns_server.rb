# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "resolv"
require "socket"

module Helpers
  # A local DNS server with fixed answers, so resolver tests never use public DNS.
  class DnsServer
    attr_reader :port, :requests

    def initialize(pause_first: false, truncate_udp: false, drop_tcp_first: false)
      @pause_first = pause_first
      @release = Thread::Queue.new
      bind_sockets(tcp: truncate_udp)
      @requests = Thread::Queue.new
      if truncate_udp
        @tcp_thread = Thread.new do
          loop do
            client = @tcp_socket.accept
            begin
              length = client.read(2)
              break unless length
              wire = client.read(length.unpack1("n"))
              if drop_tcp_first
                drop_tcp_first = false
                next
              end
              reply = response(wire).encode
              client.write([reply.bytesize].pack("n") + reply)
            ensure
              client.close
            end
          end
        end
      end
      @thread = Thread.new do
        loop do
          wire, peer = @socket.recvfrom(4096)
          break if wire.empty?
          message = response(wire)
          message.tc = 1 if truncate_udp
          if @pause_first
            @release.pop
            @pause_first = false
          end
          @socket.send(message.encode, 0, peer[3], peer[1])
        end
      end
    end

    def config
      { nameserver_port: [["127.0.0.1", port]], search: [], ndots: 1, use_ipv6: true }
    end

    def release_first
      @release << true
    end

    def close
      release_first
      @socket.send("", 0, "127.0.0.1", port) if @thread.alive?
      @thread.value
      if @tcp_thread
        TCPSocket.new("127.0.0.1", port).close if @tcp_thread.alive?
        @tcp_thread.value
      end
    ensure
      @socket.close
      @tcp_socket&.close
    end

    private

    def bind_sockets(tcp:)
      10.times do |attempt|
        @socket = @tcp_socket = nil
        # Let TCP choose a usable port, then check that UDP can share it.
        # Ephemeral ports can be reserved or occupied for only one protocol.
        @socket = UDPSocket.new
        @tcp_socket = TCPServer.new("127.0.0.1", 0) if tcp
        @socket.bind("127.0.0.1", @tcp_socket ? @tcp_socket.addr[1] : 0)
        @port = @socket.addr[1]
        return
      rescue SystemCallError => e
        @socket&.close
        @tcp_socket&.close
        raise unless attempt < 9 && (e.is_a?(Errno::EADDRINUSE) || e.is_a?(Errno::EACCES))
      end
    end

    def response(wire)
      message = ::Resolv::DNS::Message.decode(wire)
      message.qr = 1
      message.ra = 1
      message.each_question do |name, type|
        @requests << [name.to_s, type::TypeValue]
        if name.to_s == "missing.test"
          message.rcode = ::Resolv::DNS::RCode::NXDomain
          next
        end
        answer = case type::TypeValue
                 when 1  then ::Resolv::DNS::Resource::IN::A.new("192.0.2.42")
                 when 28 then ::Resolv::DNS::Resource::IN::AAAA.new("2001:db8::42")
                 when 12 then ::Resolv::DNS::Resource::IN::PTR.new(::Resolv::DNS::Name.create("answer.test"))
                 end
        message.add_answer(name, 30, answer) if answer
      end
      message
    end
  end
end
