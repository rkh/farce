# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal
    # Observe termination without consuming the Ractor's return value.
    class ProxyOwner
      include ProxyOwnerNotifications

      def self.current = Storage.store_if_absent(self) { new }

      def self.create_scheduler
        scheduler = Farce::Scheduler.new
        Fiber.set_scheduler(scheduler)
        scheduler
      end

      def self.drain_scheduler(scheduler) = scheduler.close

      def initialize
        super
        TracePoint.new(:thread_end) do |trace|
          stop
          trace.disable
        end.enable(target_thread: Ractor.main_thread)
        freeze
      end
    end
  end
end
