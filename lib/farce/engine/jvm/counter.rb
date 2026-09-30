# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/jvm/types"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Counter < Numeric
      attr_reader :initial

      def initialize(value = 0)
        raise "Counter is already initialized" if defined?(@counter)
        check_frozen!
        raise TypeError, "initial value must be an Integer" unless value.is_a?(Integer)

        @signal = Signal.new
        @initial = value
        @counter = JVMContainers::AtomicLong.new(value)
        super()
      end

      def get = @counter.get

      def store(value)
        check_frozen!
        raise TypeError, "value must be an Integer" unless value.is_a?(Integer)

        @counter.set(value)
        @signal.broadcast
        value
      end

      def swap(value)
        check_frozen!
        raise TypeError, "value must be an Integer" unless value.is_a?(Integer)

        @counter.getAndSet(value).tap { @signal.broadcast }
      end

      def add(delta = 1)
        check_frozen!
        raise TypeError, "delta must be an Integer" unless delta.is_a?(Integer)

        @counter.addAndGet(delta).tap { @signal.broadcast }
      end

      def compare_and_set(expected_value, new_value)
        check_frozen!
        raise TypeError, "expected value must be an Integer" unless expected_value.is_a?(Integer)
        raise TypeError, "replacement value must be an Integer" unless new_value.is_a?(Integer)

        @counter.compareAndSet(expected_value, new_value).tap { @signal.broadcast }
      end

      def subtract(delta = 1)
        check_frozen!
        raise TypeError, "delta must be an Integer" unless delta.is_a?(Integer)

        @counter.addAndGet(-delta).tap { @signal.broadcast }
      end

      def increment(delta = 1)
        check_frozen!
        unless delta.is_a?(Integer)
          delta = Integer(delta)
          check_frozen!
        end
        @counter.addAndGet(delta).tap { @signal.broadcast }
        self
      end

      def decrement(delta = 1)
        check_frozen!
        unless delta.is_a?(Integer)
          delta = Integer(delta)
          check_frozen!
        end
        @counter.addAndGet(-delta).tap { @signal.broadcast }
        self
      end

      alias value get
      alias value= store

      def change_signal = @signal

      private

      def check_frozen!
        raise FrozenError.new("can't modify frozen #{self.class}", receiver: self) if frozen?
      end

      def initialize_copy(other)
        @signal = Signal.new
        @initial = other.initial
        @counter = JVMContainers::AtomicLong.new(other.value)
      end
    end
  end
end
