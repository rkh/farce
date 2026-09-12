# frozen_string_literal: true
return unless RUBY_ENGINE == "ruby"
require_relative "../../setup"
require "open3"

module Farce
  module Internal
    class TestFiberSchedulerResolution < Test
      SUBPROCESS_TIMEOUT = 15

      def test_select_resolves_in_non_main_ractors
        check_non_main_ractors("select")
      end

      def test_native_resolves_in_non_main_ractors
        skip "the native epoll/kqueue scheduler is unavailable on Windows" if Gem.win_platform?
        check_non_main_ractors("native")
      end

      private

      def check_non_main_ractors(implementation)
        env = { "FARCE_FIBER_SCHEDULER_IMPLEMENTATION" => implementation, "FARCE_IO_BACKEND" => "auto" }
        output, error, status = capture3_with_timeout(env, RbConfig.ruby,
          "-I#{File.expand_path("../../../lib", __dir__)}", "-I#{File.expand_path("../..", __dir__)}", "-e", <<~RUBY)
            require "farce"
            require "helpers/dns_server"
            module Farce
              module Internal
                FiberScheduler
                batch_sizes = RUBY_VERSION.start_with?("3.4.") ? [1, 1] : [2]
                batch_sizes.each do |batch_size|
                  tasks = batch_size.times.map do
                    ::Ractor.new do
                      server = Helpers::DnsServer.new(pause_first: true)
                      dns = Resolv::DNS.new(server.config)
                      dns.timeouts = 2
                      Storage[Resolv] = Resolv.new([dns])
                      pool = Object.new
                      def pool.call(*) = raise("DNS used the background pool")
                      scheduler = FiberScheduler.new(thread_pool: pool)
                      addresses = nil
                      progressed = false
                      Fiber.set_scheduler(scheduler)
                      Fiber.schedule { addresses = scheduler.address_resolve("answer.test") }
                      Fiber.schedule do
                        server.requests.pop
                        progressed = true
                        server.release_first
                      end
                      scheduler.run
                      raise "other fiber stalled" unless progressed
                      raise "hostname lookup failed" unless addresses.sort == %w[192.0.2.42 2001:db8::42]
                      Fiber.schedule do
                        raise "IPv4 lookup failed" unless scheduler.address_resolve("127.0.0.1") == ["127.0.0.1"]
                        raise "IPv6 lookup failed" unless scheduler.address_resolve("::1") == ["::1"]
                        raise "missing lookup failed" unless scheduler.address_resolve("missing.test").empty?
                        entries = Addrinfo.getaddrinfo("answer.test", 80, :UNSPEC, :STREAM)
                        raise "runtime lookup failed" unless entries.any? { |entry| entry.ip_address == "192.0.2.42" }
                      end
                      scheduler.run
                      Fiber.set_scheduler(nil)
                      raise "scheduler not closed" unless scheduler.closed?
                      true
                    ensure
                      server&.release_first
                      Fiber.set_scheduler(nil)
                      dns&.close
                      server&.close
                    end
                  end
                  tasks.each do |task|
                    raise "ractor failed" unless task.respond_to?(:value) ? task.value : task.take
                  end
                end
                puts "ok"
              end
            end
          RUBY

        assert_predicate status, :success?, error
        assert_equal "ok", output.strip
      end

      def capture3_with_timeout(env, *command)
        Open3.popen3(env, *command) do |input, output, error, waiter|
          input.close
          output_reader = Thread.new { output.read }
          error_reader = Thread.new { error.read }

          unless waiter.join(SUBPROCESS_TIMEOUT)
            Process.kill("KILL", waiter.pid)
            waiter.join

            flunk <<~MESSAGE
              scheduler resolution subprocess timed out after #{SUBPROCESS_TIMEOUT} seconds
              stdout:
              #{output_reader.value}
              stderr:
              #{error_reader.value}
            MESSAGE
          end

          [output_reader.value, error_reader.value, waiter.value]
        end
      end
    end
  end
end
