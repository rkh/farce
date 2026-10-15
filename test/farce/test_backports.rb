# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestBackports < Test
    def test_direct_calls
      assert_backports :direct
    end

    def test_refinements
      assert_backports :refined
    end

    def test_global_installation
      assert_backports :global
    end

    def test_alive_direct_calls
      assert_alive_backports :direct
    end

    def test_alive_refinements
      assert_alive_backports :refined
    end

    def test_alive_global_installation
      assert_alive_backports :global
    end

    def test_autoloads_from_shim_ractor
      return unless RUBY_ENGINE == "jruby"

      output, error, status = ruby_isolated(<<~RUBY)
        require "farce"
        raise "Backports was already loaded" unless Farce.autoload?(:Backports)

        worker = Farce::Ractor.new { Farce::Backports.alive?(Farce::Ractor.current) }
        raise "worker Ractor is not alive" unless worker.value == true
        raise "main Ractor is not alive" unless Farce::Backports.alive?(Farce::Ractor.main) == true
      RUBY

      assert_predicate status, :success?, "#{output}\n#{error}"
    end

    def test_alive_ractors_created_before_loading_farce
      return unless RUBY_ENGINE == "ruby" && RUBY_VERSION < "4"

      output, error, status = ruby_isolated(<<~RUBY)
        require "zeitwerk" rescue nil

        running = Ractor.new { Ractor.receive }
        terminated = Ractor.new { :done }
        terminated.take

        require "farce"

        raise "running Ractor is not alive" unless Farce::Backports.alive?(running) == true
        raise "terminated Ractor is alive" unless Farce::Backports.alive?(terminated) == false
        running.send(:done)
        raise "alive? consumed the result" unless running.take == :done
        raise "finished Ractor is alive" unless Farce::Backports.alive?(running) == false
      RUBY

      assert_predicate status, :success?, "#{output}\n#{error}"
    end

    def test_monitor_main
      port = Farce::Port.new

      assert Backports.monitor(Ractor.main, port)
      assert Backports.unmonitor(Ractor.main, port)
    ensure
      port&.close
    end

    def test_monitor_old_ractor
      return unless RUBY_ENGINE == "ruby"

      output, error, status = ruby_isolated(<<~RUBY)
        require "zeitwerk" rescue nil

        ractor = Ractor.new { true }
        ractor.respond_to?(:take) ? ractor.take : ractor.join

        require "farce"
        Farce::Backports.install

        port = Ractor::Port.new
        ractor.monitor(port)

        result = port.receive
        result = result.last if result.is_a? Array
        raise "monitor failed: " + result.inspect unless result == :exited
      RUBY

      assert_predicate status, :success?, "#{output}\n#{error}"
    end

    private

    def assert_alive_backports(activation)
      setup = case activation
              when :refined then "using Farce::Backports"
              when :global then "Farce::Backports.install"
              end
      alive = if activation == :direct
                ->(receiver) { "Farce::Backports.alive?(#{receiver})" }
              else
                ->(receiver) { "#{receiver}.alive?" }
              end
      output, error, status = ruby_isolated(<<~RUBY)
        require "farce"
        require "farce/backports"
        #{setup}

        events = Farce::Ractor::Port.new
        ractor = Farce::Ractor.new(events) do |events|
          events.send(#{alive.call("Farce::Ractor.current")})
          Farce::Ractor.receive
        end
        2.times do
          raise "waiting Ractor is not alive" unless #{alive.call("ractor")} == true
        end
        raise "current Ractor is not alive" unless events.receive == true
        ractor.send(:done)
        result = ractor.respond_to?(:value) ? ractor.value : ractor.take
        raise "alive? consumed the result" unless result == :done
        2.times do
          raise "terminated Ractor is alive" unless #{alive.call("ractor")} == false
        end
        events.close

        ractor = Farce::Ractor.new do
          Thread.current.report_on_exception = false
          raise "expected failure"
        end
        begin
          ractor.respond_to?(:value) ? ractor.value : ractor.take
          raise "missing Ractor failure"
        rescue Farce::Ractor::RemoteError, RuntimeError => error
          failure = error.cause || error
          raise unless failure.message == "expected failure"
        end
        raise "aborted Ractor is alive" unless #{alive.call("ractor")} == false
        raise "main Ractor is not alive" unless #{alive.call("Farce::Ractor.main")} == true
      RUBY

      assert_predicate status, :success?, "#{output}\n#{error}"
    end

    def assert_backports(activation)
      setup = case activation
              when :direct
                ""
              when :refined
                "using Farce::Backports"
              when :global
                <<~RUBY
                  Farce::Backports.install
                  raise "installation is not idempotent" if Farce::Backports.install
                  raise "Ractor missing" unless Ractor
                  raise "Port missing" unless Ractor::Port
                RUBY
              end
      dispatch = if activation == :direct
                   ->(name, args) { "Farce::Backports.#{name}(ractor#{args})" }
                 else
                   ->(name, args) { "ractor.#{name}(#{args.delete_prefix(", ")})" }
                 end
      output, error, status = ruby_isolated(<<~RUBY)
        require "farce"
        #{setup}
        ractor = Farce::Ractor.new { Farce::Ractor.receive }
        port = Farce::Ractor::Port.new
        default_port = #{dispatch.call(:default_port, "")}
        raise "monitor failed" unless #{dispatch.call(:monitor, ", port")}
        default_port.send(:done)
        notification = port.receive
        notification = notification.last if notification.is_a?(Array)
        raise "wrong exit notification" unless notification == :exited
        #{dispatch.call(:join, "")}

        ractor = Farce::Ractor.new { Farce::Ractor.receive }
        #{dispatch.call(:monitor, ", port")}
        #{dispatch.call(:unmonitor, ", port")}
        #{dispatch.call(:default_port, "")}.send(:done)
        #{dispatch.call(:join, "")}
        port.send(:sentinel)
        raise "unmonitor left a notification" unless port.receive == :sentinel
      RUBY

      assert_predicate status, :success?, "#{output}\n#{error}"
    end
  end
end
