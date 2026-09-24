# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal
    case FROZEN_CONFIG.fiber_scheduler_implementation
    when :native
      load_native_fiber_scheduler
    when :select
      class FiberScheduler
        include SelectScheduler
      end
    when :jvm
      raise LoadError, "the JVM fiber scheduler requires JRuby"
    end

    unless FiberScheduler.private_method_defined?(:scheduler_ready_count)
      class FiberScheduler
        private def scheduler_ready_count = ready? ? 1 : 0
      end
    end

    class FiberScheduler
      # Opt into native wait hooks when a Ractor operation needs the shared selector.
      def ractor_selector = RactorSelector.current
    end

    FiberScheduler.prepend(SchedulerLifecycle)
    require "farce/engine/ruby/3.4/fiber_scheduler" unless Internal.native_ports?
  end
end
