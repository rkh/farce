# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Signal
      include Freeze::Unfreezable

      TIMED_OUT = Object.new.freeze
      private_constant :TIMED_OUT

      def initialize
        @generation     = TruffleRuby::AtomicReference.new(0)
        @num_waiting    = TruffleRuby::AtomicReference.new(0)
        @condition      = ConditionVariable.new
        @broadcast_lock = Mutex.new
        Freeze.publish(self)
      end

      def generation  = @generation.get
      def num_waiting = @num_waiting.get

      def broadcast
        @broadcast_lock.synchronize do
          generation = @generation.get + 1
          @generation.set(generation)
          @condition.broadcast
          generation
        end
      end

      def wait(observed = nil, timeout: nil, &fallback)
        validate_generation(observed) unless observed.nil?
        deadline = timeout_deadline(timeout)

        result = @broadcast_lock.synchronize do
          observed ||= generation
          waiting = false
          begin
            loop do
              current = generation
              break current unless current == observed

              remaining = deadline - Clock.now if deadline
              break TIMED_OUT if remaining && !remaining.positive?
              @num_waiting.set(@num_waiting.get + 1) unless waiting
              waiting = true
              @condition.wait(@broadcast_lock, remaining)
            end
          ensure
            @num_waiting.set(@num_waiting.get - 1) if waiting
          end
        end

        TIMED_OUT.equal?(result) ? fallback&.call : result
      end

      private

      def validate_generation(generation)
        raise TypeError, "generation must be an Integer" unless generation.is_a?(::Integer)
      end

      def timeout_deadline(timeout)
        return if timeout.nil?

        timeout = Float(timeout)
        if !timeout.finite? || timeout.negative?
          raise ArgumentError, "timeout must be a finite, non-negative number or nil"
        end
        Clock.now + timeout
      end
    end
  end
end
