# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Wait for shim port readiness without consuming messages from losing ports.
    class RactorSelector
      def select(*sources, timeout: nil)
        raise ArgumentError, "specify at least one Ractor::Port or Ractor" if sources.empty?
        sources.each do |source|
          next if source.is_a?(Ractor) || source.is_a?(Port)
          raise ArgumentError, "should be Ractor::Port or Ractor"
        end

        timeout  = duration(timeout)
        deadline = Clock.now + timeout if timeout
        monitors = {}.compare_by_identity
        ports    = sources.uniq.map do |source|
          next source unless source.is_a?(Ractor)

          port           = BasePort.new
          monitors[port] = source
          source.monitor(port)
          port
        end

        result = wait(ports, deadline)
        return unless result

        port, value = result
        ractor      = monitors[port]
        ractor ? [ractor, ractor.value] : [port, value]
      ensure
        monitors&.each do |port, ractor|
          ractor.unmonitor(port)
          port.close
        end
      end

      private

      def duration(value)
        return if value.nil?
        raise TypeError, "cannot convert String into time interval" if value.is_a?(String)
        value = Float(value)
        raise RangeError, "timeout out of range" unless value.finite?
        raise ArgumentError, "time interval must not be negative" if value.negative?
        value
      end

      def wait(ports, deadline)
        wakeup = Thread::Queue.new
        ports.each { it.register_selector(wakeup) }
        loop do
          # Clear before checking readiness. A concurrent send either appears
          # in that check or leaves a notification for the following wait.
          wakeup.clear
          ports.each do |port|
            result = port.select_receive
            return result if result
          end
          remaining = deadline - Clock.now if deadline
          return if remaining && !remaining.positive?
          return unless wakeup.pop(timeout: remaining)
        end
      ensure
        ports.each { it.unregister_selector(wakeup) }
      end
    end
  end
end
