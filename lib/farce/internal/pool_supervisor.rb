# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal # :nodoc: all
    # Runs delayed pool control work outside application Ractors.
    class PoolSupervisorService
      include Shareable

      STOP = :stop
      private_constant :STOP

      def initialize
        @queue  = TimerQueue.new(mode: :raise)
        @closed = Atom.new(false)
        @worker = Ractor.new(@queue, name: "farce-pool-supervisor") do |queue|
          while (entry = queue.pop) != STOP
            pool, token = entry
            pool.scale_if_needed(token)
          end
        end
        super
      end

      def schedule(pool, token, delay)
        raise ::Farce::Queue::ClosedError, "pool supervisor is closed" if @closed.value
        @queue.push([pool, token].freeze, delay:)
      end

      def close
        return unless @closed.compare_and_set(false, true)
        @queue.push(STOP, clock: 0)
        @worker.respond_to?(:join) ? @worker.join : @worker.take
      end
    end

    PoolSupervisor = PoolSupervisorService.new
    at_exit { PoolSupervisor.close }
  end
end
