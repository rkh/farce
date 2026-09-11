# frozen_string_literal: true

module Farce
  module Internal
    case CONFIG.freeze.fiber_scheduler_implementation
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

    FiberScheduler.prepend(SchedulerLifecycle)
  end
end
