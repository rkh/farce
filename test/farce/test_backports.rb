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

    def test_value_direct_calls
      assert_value_backports :direct
    end

    def test_value_refinements
      assert_value_backports :refined
    end

    def test_value_global_installation
      assert_value_backports :global
    end

    def test_port_receive_direct_calls
      assert_receive_backports :direct, :port
    end

    def test_port_receive_refinements
      assert_receive_backports :refined, :port
    end

    def test_port_receive_global_installation
      assert_receive_backports :global, :port
    end

    def test_ractor_receive_direct_calls
      assert_receive_backports :direct, :ractor
    end

    def test_ractor_receive_refinements
      assert_receive_backports :refined, :ractor
    end

    def test_ractor_receive_global_installation
      assert_receive_backports :global, :ractor
    end

    def test_select_direct_calls
      assert_select_backports :direct
    end

    def test_select_refinements
      assert_select_backports :refined
    end

    def test_select_global_installation
      assert_select_backports :global
    end

    def test_value_retains_backported_results
      return unless RUBY_ENGINE == "ruby" && RUBY_VERSION < "4"

      [42, nil, false, ["result"]].each do |expected|
        ractor = Farce::Ractor.new(expected) { |value| value }
        result = Backports.value(ractor)

        2.times do
          if result.nil?
            assert_nil Backports.value(ractor)
          else
            assert_same result, Backports.value(ractor)
          end
        end
      end
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

    def assert_receive_backports(activation, source)
      setup = case activation
              when :refined then "using Farce::Backports"
              when :global then "Farce::Backports.install"
              end
      receiver = source == :port ? "source.receive" : "receive"
      receive = if activation == :direct
                  ->(args) { "Farce::Backports.receive(source#{args})" }
                else
                  ->(args) { "#{receiver}(#{args.delete_prefix(", ")})" }
                end
      checks = <<~RUBY
        raise "zero timeout did not expire" unless #{receive.call(", timeout: 0")}.nil?
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise "positive timeout did not expire" unless #{receive.call(", timeout: 0.01")}.nil?
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        raise "receive returned before its timeout" if elapsed < 0.01

        [false, nil, :message].each do |expected|
          source.send(expected)
          source.send(:sentinel)
          raise "wrong received value" unless #{receive.call(", timeout: 1")} == expected
          raise "receive consumed the next message" unless #{receive.call(", timeout: 0")} == :sentinel
        end

        source.send(:without_timeout)
        raise "receive without timeout failed" unless #{receive.call("")} == :without_timeout
        source.send(:nil_timeout)
        raise "receive with nil timeout failed" unless #{receive.call(", timeout: nil")} == :nil_timeout
      RUBY
      body = if source == :port
               <<~RUBY
                 port_class = defined?(::Ractor::Port) ? ::Ractor::Port : Farce::Ractor::Port
                 source = port_class.new
                 #{checks}
                 source.close
               RUBY
             else
               <<~RUBY
                 worker = Farce::Ractor.new do
                   source = Farce::Ractor.current
                   #{checks}
                   :passed
                 end
                 raise "Ractor receive checks failed" unless Farce::Backports.value(worker) == :passed
               RUBY
             end
      output, error, status = ruby_isolated(<<~RUBY)
        require "farce"
        require "farce/backports"
        #{setup}
        #{body}
      RUBY

      assert_predicate status, :success?, "#{output}\n#{error}"
    end

    def assert_select_backports(activation)
      skip "RactorMethods#select is not implemented on non-CRuby" unless RUBY_ENGINE == "ruby"

      setup = case activation
              when :refined then "using Farce::Backports"
              when :global then "Farce::Backports.install"
              end
      select = activation == :direct ? "Farce::Backports.select" : "::Ractor.select"
      output, error, status = ruby_isolated(<<~RUBY)
        require "farce"
        require "farce/backports"
        #{setup}

        port_class = defined?(::Ractor::Port) ? ::Ractor::Port : Farce::Ractor::Port
        first = port_class.new
        second = port_class.new
        raise "zero timeout did not expire" unless #{select}(first, second, timeout: 0).nil?
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise "positive timeout did not expire" unless #{select}(first, second, timeout: 0.01).nil?
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        raise "select returned before its timeout" if elapsed < 0.01

        [false, nil, :message].each do |expected|
          second.send(expected)
          raise "wrong selected source or value" unless #{select}(first, second, timeout: 1) == [second, expected]
          first.send(:sentinel)
          raise "select consumed the next message" unless #{select}(first, second, timeout: 0) == [first, :sentinel]
        end

        first.send(:without_timeout)
        raise "select without timeout failed" unless #{select}(first, second) == [first, :without_timeout]
        second.send(:nil_timeout)
        raise "select with nil timeout failed" unless #{select}(first, second, timeout: nil) == [second, :nil_timeout]

        worker = Farce::Ractor.new { Farce::Ractor.receive }
        raise "waiting Ractor did not time out" unless #{select}(worker, first, timeout: 0).nil?
        worker.send(:result)
        raise "wrong Ractor result" unless #{select}(worker, first, timeout: 5) == [worker, :result]
        first.close
        second.close
      RUBY

      assert_predicate status, :success?, "#{output}\n#{error}"
    end

    def assert_value_backports(activation)
      setup = case activation
              when :refined then "using Farce::Backports"
              when :global then "Farce::Backports.install"
              end
      value = activation == :direct ? "Farce::Backports.value(ractor)" : "ractor.value"
      output, error, status = ruby_isolated(<<~RUBY)
        require "farce"
        require "farce/backports"
        #{setup}

        events = Farce::Ractor::Port.new
        [42, nil, false, ["result"]].each do |expected|
          ractor = Farce::Ractor.new(events) do |events|
            events.send(:ready)
            Farce::Ractor.receive
          end
          reader = Thread.new { #{value} }
          raise "Ractor did not start" unless events.receive == :ready
          raise "value returned before the Ractor finished" if reader.join(0)
          ractor.send(expected)
          result = reader.value
          raise "wrong Ractor value" unless result == expected
        end
        events.close

        ractor = Farce::Ractor.new do
          Thread.current.report_on_exception = false
          raise "expected failure"
        end
        begin
          #{value}
          raise "missing Ractor failure"
        rescue Farce::Ractor::RemoteError, RuntimeError => error
          failure = error.cause || error
          raise unless failure.message == "expected failure"
        end
      RUBY

      assert_predicate status, :success?, "#{output}\n#{error}"
    end

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
