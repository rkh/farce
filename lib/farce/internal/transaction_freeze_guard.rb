# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal # :nodoc: all
    # Keep a Local handle's shared freeze state stable across a foreign commit.
    # Reads retain the atomic flag. Only freeze and mixed commits take the lock.
    class TransactionFreezeGuard
      include Shareable::Immutable

      attr_reader :native_flag, :lock

      def initialize(value)
        @native_flag = Flag.new(value)
        @lock = Farce::Lock.new
        super()
      end

      def value = @native_flag.value

      def set
        @lock.synchronize do
          yield if block_given?
          @native_flag.set
        end
      end
    end
  end
end
