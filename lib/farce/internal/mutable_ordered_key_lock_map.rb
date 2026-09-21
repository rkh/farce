# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Coordinate mutable keys by ordering within one Ractor.
    # SortedSet uses this for backing trees whose keys cannot be published.
    class MutableOrderedKeyLockMap
      Gate = Struct.new(:lock, :participants)
      private_constant :Gate

      def initialize
        @guard        = Farce::Lock.new
        @entries      = MutableTreeMap.new
        @participants = 0
      end

      def synchronize(key, &)
        raise LocalJumpError, "no block given" unless block_given?

        gate = nil
        registered = false
        begin
          Thread.handle_interrupt(INTERRUPT_MASK) do
            @guard.synchronize do
              gate = @entries[key]
              unless gate
                gate = Gate.new(KeyLockMap.new(registry_class: Farce::Strict::Map), 0)
                @entries[key] = gate
              end
              gate.participants += 1
              @participants += 1
              registered = true
            end
          end
          gate.lock.synchronize(:operation, &)
        ensure
          release(key, gate) if registered
        end
      end

      private

      def release(key, gate)
        Thread.handle_interrupt(INTERRUPT_MASK) do
          @guard.synchronize do
            gate.participants -= 1
            @participants -= 1
            if @participants.zero?
              @entries.clear
            elsif gate.participants.zero?
              @entries.delete(key)
            end
          end
        end
      end
    end
  end
end
