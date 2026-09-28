# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal
    class ProxyOwner
      include ProxyOwnerNotifications

      class OwnerScheduler < Farce::ThreadScheduler
        def initialize
          @threads = Thread::Queue.new
          super
        end

        def schedule(*, **, &)
          @threads << Thread.new(*, &)
          self
        end

        def join
          @threads.pop.join until @threads.empty?
        end
      end
      private_constant :OwnerScheduler

      def self.create_scheduler
        Storage[:local_scheduler] = OwnerScheduler.new
      end

      def self.drain_scheduler(scheduler) = scheduler.join

      def self.current = Storage.store_if_absent(self) { new }

      def initialize
        super
        Ractor.current.monitor(self)
      end

      def <<(_) = stop
    end
  end
end
