# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # Backports for Ractor and related functionality to older Ruby versions.
  #
  # ## Activating Backports
  #
  # There are three ways of using these backports:
  # * Activating them globally via: {.install}
  # * Using them within a specific scope via refinements: `using Farce::Backports`
  # * Calling methods on `Farce::Backports` directly
  #
  # Only the first method will also define the global constants `Ractor` and `Ractor::Port`
  # if they are not natively available.
  #
  # @example Activating the backports globally
  #   Farce::Backports.install
  #   port = Ractor.current.default_port
  #
  # @example Using the backports within a specific namespace via refinements
  #   # Within a namespace
  #   module MyNamespace
  #     using Farce::Backports
  #
  #     def self.send_to(ractor_or_port, message)
  #       port = ractor_or_port.default_port if ractor_or_port.is_a?(Ractor)
  #       port.send(message)
  #     end
  #   end
  #
  # @example Activating the backports for a specific file
  #   # top level of the file
  #   using Farce::Backports
  #
  #   ractor  = Ractor.new { sleep 10 }
  #   monitor = Ractor.new { puts "exit status: #{receive}" }
  #
  #   monitor.monitor(ractor.default_port)
  #   monitor.join
  #
  # @example Activating the backports for a given proc (Ruby 4.1+ only)
  #   callback = ->(ractor) { ractor.default_port }
  #   callback.refined(Farce::Backports).call(Ractor.current)
  #
  # @example Calling methods on `Farce::Backports` directly
  #   port = Farce::Backports.default_port(Ractor.current)
  #
  # @!method alive?(ractor)
  #   @scope class
  #   Backport for {https://docs.ruby-lang.org/en/master/Ractor.html#method-i-alive-3F Ractor#alive?}
  #   @example
  #     using Farce::Backports
  #     ractor = Ractor.new { sleep 10 }
  #     ractor.alive? # => true
  #   @param ractor [Ractor] the ractor to check
  #   @return [Boolean] whether the ractor is alive
  #
  # @!method default_port(ractor)
  #   @scope class
  #   Backport for {https://docs.ruby-lang.org/en/4.0/Ractor.html#method-i-default_port Ractor.default_port}
  #   @example
  #     using Farce::Backports
  #     ractor = Ractor.new { puts receive }
  #     port   = ractor.default_port
  #     port.send("message")
  #   @param ractor [Ractor] the ractor for which to obtain the default port
  #   @return [Ractor::Port] the default port of the given ractor
  #
  # @!method monitor(ractor, port)
  #   @scope class
  #   Backport for {https://docs.ruby-lang.org/en/4.0/Ractor.html#method-i-monitor Ractor#monitor}
  #   @example
  #     using Farce::Backports
  #     ractor = Ractor.new { raise "I'm not happy!" }
  #     port   = Farce::Ractor::Port.new
  #     ractor.monitor(port)
  #     port.receive # => :aborted
  #   @param ractor [Ractor] the ractor to monitor
  #   @param port [Ractor::Port] the port to monitor the ractor with
  #   @return [Boolean] whether the Ractor was still running when the monitor was set up
  #
  # @!method unmonitor(ractor, port)
  #   @scope class
  #   Backport for {https://docs.ruby-lang.org/en/4.0/Ractor.html#method-i-unmonitor Ractor#unmonitor}
  #   @example
  #     using Farce::Backports
  #     ractor = Ractor.new { sleep 10; raise "I'm not happy!" }
  #     port   = Farce::Ractor::Port.new
  #     ractor.monitor(port)
  #     ractor.unmonitor(port)
  #     port.receive # blocks forever
  #   @param ractor [Ractor] the ractor to unmonitor
  #   @param port [Ractor::Port] the port to unmonitor the ractor with
  #   @return [Ractor] the unmonitored ractor
  #
  # @!method join(ractor)
  #   @scope class
  #   Backport for {https://docs.ruby-lang.org/en/4.0/Ractor.html#method-i-join Ractor#join}
  #   @example
  #     using Farce::Backports
  #     ractor = Ractor.new { sleep 10 }
  #     ractor.join # blocks until the ractor exits
  #   @param ractor [Ractor] the ractor to join
  #   @return [Ractor] the joined ractor
  module Backports
    # @!visibility private
    Extension = Farce::Extension.new
    private_constant :Extension
    include Extension

    if Internal.native_ractors?
      if Internal.native_ports?
        unless ::Ractor.method_defined?(:alive?)
          Extension.define(::Ractor) do
            def alive? = Backports.alive?(self)
          end

          def self.alive?(ractor)
            ractor.monitor(NULL_PORT)
          ensure
            ractor.unmonitor(NULL_PORT)
          end
        end
      else
        Extension.define(::Ractor) do
          def alive?          = Backports.alive?(self)
          def default_port    = Backports.default_port(self)
          def join            = Backports.join(self)
          def monitor(port)   = Backports.monitor(self, port)
          def unmonitor(port) = Backports.unmonitor(self, port)
        end

        def self.default_port(ractor) = Farce::Ractor::Port.new(ractor)

        def self.alive?(ractor)
          return true if Ractor.main == ractor
          state = Internal::RactorState.for(ractor)
          return state.alive? if state
          !ractor.inspect.end_with?("terminated>")
        end

        def self.join(ractor)
          Internal::RactorState.for(ractor)&.join
          ractor
        end

        def self.monitor(ractor, port)
          return true if Ractor.main == ractor

          state = Internal::RactorState.for(ractor)
          return state.monitor(port) if state

          raise Ractor::Error, "#{ractor.inspect} cannot be monitored" unless ractor.inspect.end_with?("terminated>")

          success = true

          begin
            ractor.take
          rescue Ractor::ClosedError
            # no-op
          rescue Ractor::RemoteError
            success = false
          end

          port.send(success ? :exited : :aborted)
          false
        end

        def self.unmonitor(ractor, port)
          Internal::RactorState.for(ractor)&.unmonitor(port)
          ractor
        end
      end
    end

    %i[default_port join monitor unmonitor alive?].each do |method|
      next if respond_to?(method)
      class_eval <<~RUBY, __FILE__, __LINE__ + 1
        def self.#{method}(ractor, ...) = ractor.#{method}(...)
      RUBY
    end

    # Installs the Farce backports for Ractor and Ractor::Port globally.
    def self.install
      Extension.install do
        if Internal.native_ractors?
          ::Ractor.const_set(:Port, Farce::Ractor::Port) unless Internal.native_ports?
        else
          Object.const_set(:Ractor, Farce::Ractor)
        end
      end
    end
  end
end
