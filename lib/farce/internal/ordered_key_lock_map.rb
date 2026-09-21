# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Coordinate keys using their ordering, independently of their hash values.
    class OrderedKeyLockMap
      include Shareable::Unfreezable

      Gate = Data.define(:lock, :participants)
      private_constant :Gate

      def initialize
        @guard        = Farce::Lock.new
        @entries      = ShareableTreeMap.new
        @participants = Counter.new(0)
        super
      end

      def synchronize(key, &)
        raise LocalJumpError, "no block given" unless block_given?

        gate       = nil
        registered = false

        begin
          Thread.handle_interrupt(INTERRUPT_MASK) do
            @guard.synchronize do
              gate = @entries[key]
              unless gate
                gate = Gate.new(KeyLockMap.new(registry_class: Farce::Strict::Map), Counter.new(0))
                Ractor.make_shareable(gate) if Internal.native_ractors?
                @entries[key] = gate
              end
              gate.participants.add(1)
              @participants.add(1)
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
            remaining = gate.participants.add(-1)
            total = @participants.add(-1)
            # Clearing needs no comparisons. It also reclaims idle records left
            # behind when a comparator raised during an earlier cleanup.
            if total.zero?
              @entries.clear
            elsif remaining.zero?
              @entries.delete(key)
            end
          end
        end
      end
    end
  end
end
