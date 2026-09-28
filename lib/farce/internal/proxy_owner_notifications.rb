# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal
    # Close proxy channels when their owner exits, without retaining unused proxies.
    module ProxyOwnerNotifications
      def initialize
        @alive = Flag.new(true)
        @supervisors = Strict::Map.new(compare_by_identity: true)
      end

      def alive? = @alive.value

      def register(supervisor)
        @supervisors[supervisor] = true
        supervisor.stop unless alive?
      end

      def unregister(supervisor) = @supervisors.delete(supervisor)

      def stop
        @alive.value = false
        @supervisors.each_key(&:stop)
      end
    end
  end
end
