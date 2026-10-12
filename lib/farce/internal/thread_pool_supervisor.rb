# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal # :nodoc: all
    # A Ractor-local service for delayed pool growth and executor shutdown requests.
    class ThreadPoolSupervisor
      include Farce::Unshareable

      def self.current = Storage.store_if_absent(self) { new }

      def initialize
        @queue  = TimerQueue.new(mode: :raise)
        @closed = Atom.new(false)
        @worker = Thread.new do
          loop do
            entry = @queue.pop
            break if entry == :stop
            pool, token = entry
            pool = pool.value
            token == :close ? pool.close : pool.scale_if_needed(token)
          end
        end
        super
      end

      def close_handle(pool) = [@queue, Envelope::Local.new(pool)].freeze

      def schedule(pool, token, delay)
        raise ::Farce::ClosedQueueError, "pool supervisor is closed" if @closed.value
        @queue.push([Envelope::Local.new(pool), token].freeze, delay:)
      end

      def close
        return unless @closed.compare_and_set(false, true)
        @queue.push(:stop, clock: 0)
        @worker.join
        @queue.close
      end
    end

    at_exit { Storage[ThreadPoolSupervisor]&.close }
  end
end
