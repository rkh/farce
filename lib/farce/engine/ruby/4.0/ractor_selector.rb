# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/ruby/shared/ractor_selector"

module Farce
  module Internal
    class RactorSelector
      def self.install_hooks(patch)
        if ::Ractor::Port.instance_method(:receive).parameters.include?(%i[key timeout])
          patch[::Ractor.singleton_class, :select, signature: "*sources, **options", schedule: "*sources, **options"]
          patch[::Ractor.singleton_class, :receive, schedule: "::Ractor.current, ..."]
          patch[::Ractor, :receive]
          patch[::Ractor::Port, :receive]
        else
          # Ruby 4.0 treats unsupported keywords as a positional Hash. Preserve
          # its native argument error before consulting a cooperative scheduler.
          patch[::Ractor.singleton_class, :select, signature: "*sources", schedule: "*sources",
            before: "return select!(*sources) if sources.last.is_a?(Hash)"]
          patch[::Ractor.singleton_class, :receive, signature: "", schedule: "::Ractor.current"]
          patch[::Ractor, :receive, signature: "", schedule: "self"]
          patch[::Ractor::Port, :receive, signature: "", schedule: "self"]
        end
        patch[::Ractor, :join, :value, signature: "", schedule: "self"]
      end

      def ractor_receive(source, timeout: nil) = wait([receive_source(source)], timeout)&.at(1)

      def ractor_select(*sources, timeout: nil)
        raise ArgumentError, "specify at least one Ractor or port" if sources.empty?
        # Monitor termination without consuming the Ractor's result. Only the
        # selected caller retrieves that result, so a timeout leaves it available.
        monitors = {}.compare_by_identity
        ports    = sources.map do |source|
          if source.is_a?(::Ractor)
            port = ::Ractor::Port.new
            monitors[port] = source
            source.monitor(port)
            port
          else
            source
          end
        end
        return unless result = wait(ports, timeout)
        source, value = result
        ractor        = monitors[source]
        ractor ? [ractor, native { ractor.value }] : [source, value]
      ensure
        monitors&.each do |port, ractor|
          ractor.unmonitor(port)
          port.close
          forget(port)
        end
      end
      alias select ractor_select

      def ractor_join(ractor, timeout: nil)
        terminated(ractor, timeout) { native { ractor.join } }
      end

      def ractor_value(ractor, timeout: nil)
        terminated(ractor, timeout) { native { ractor.value } }
      end

      private

      def receive_source(source)  = source.is_a?(::Ractor) ? source.default_port : source
      def fallback_port?(_source) = false
      def build_control           = ::Ractor::Port.new
      def receive_control         = @control.receive
      def close_control           = @control.close

      # Native ports are closed by CRuby during Ractor teardown. Closing them
      # again from the dying helper can crash the VM.
      def cleanup_control; end

      def check_closed(source)
        raise ::Ractor::ClosedError, "The port was already closed" if source.closed?
      end

      def validate_source(source)
        return if source.is_a?(::Ractor)
        raise ArgumentError, "expected a Ractor or port" unless source.is_a?(::Ractor::Port)
        inspect_port = ::Ractor::Port.instance_method(:inspect)
        # Native ports expose their owner only through the built-in inspect.
        owner = inspect_port.bind_call(@owner.default_port)[/to:#\d+/]
        return if inspect_port.bind_call(source)[/to:#\d+/] == owner
        raise ::Ractor::Error, "only allowed from the creator Ractor of this port"
      end

      # Readiness is separate from result retrieval. In particular, join must
      # wait for termination without taking the value another caller may need.
      def terminated(ractor, timeout)
        port = ::Ractor::Port.new
        ractor.monitor(port)
        return unless wait([port], timeout)
        yield
      ensure
        if port
          ractor.unmonitor(port)
          port.close
          forget(port)
        end
      end
    end
  end
end
