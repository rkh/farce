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
        raise "monitor failed" unless result == :exited
      RUBY

      assert_predicate status, :success?, "#{output}\n#{error}"
    end

    private

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
