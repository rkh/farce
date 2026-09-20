# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/jvm/types"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Counter < Numeric
      def initialize(value = 0)
        raise TypeError, "initial value must be an Integer" unless value.is_a?(Integer)

        @counter = JVMContainers::AtomicLong.new(value)
        super()
        freeze
      end

      def get = @counter.get

      def store(value)
        raise TypeError, "value must be an Integer" unless value.is_a?(Integer)

        @counter.set(value)
        value
      end

      def swap(value)
        raise TypeError, "value must be an Integer" unless value.is_a?(Integer)

        @counter.getAndSet(value)
      end

      def add(delta = 1)
        raise TypeError, "delta must be an Integer" unless delta.is_a?(Integer)

        @counter.addAndGet(delta)
      end

      def compare_and_set(expected_value, new_value)
        raise TypeError, "expected value must be an Integer" unless expected_value.is_a?(Integer)
        raise TypeError, "replacement value must be an Integer" unless new_value.is_a?(Integer)

        @counter.compareAndSet(expected_value, new_value)
      end

      def subtract(delta = 1)
        raise TypeError, "delta must be an Integer" unless delta.is_a?(Integer)

        @counter.addAndGet(-delta)
      end

      def increment(delta = 1)
        @counter.addAndGet(Integer(delta))
        self
      end

      def decrement(delta = 1)
        @counter.addAndGet(-Integer(delta))
        self
      end

      alias value get
      alias value= store

      private def initialize_copy(other) = @counter = JVMContainers::AtomicLong.new(other.value)
    end
  end
end
