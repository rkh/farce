# frozen_string_literal: true

module Farce
  module Internal
    case CONFIG.freeze.fiber_scheduler_implementation
    when :native
      require "#{ENGINE_PATH}/fiber_scheduler"
    when :select
      class FiberScheduler
        include SelectScheduler
      end
    when :jvm
      raise LoadError, "the JVM fiber scheduler requires JRuby"
    end

    FiberScheduler.prepend(SchedulerLifecycle)
  end
end
