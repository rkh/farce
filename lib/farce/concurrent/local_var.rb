# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Concurrent
    # @!visibility private
    class LocalVar # :nodoc: all
      include Abstract::Value
      include Internal::Freeze::Tracked
      include Internal::MarshalSupport::Reject

      def initialize(scope, default = nil, &block)
        @scope = scope

        if block
          @default_block = try_shareable(block)
          @default       = nil
        else
          @default_block = nil
          @default       = default
        end

        super()
        __freeze__
      end

      def bind(value)
        check_frozen!
        return unless block_given?
        current_storage       = storage
        old_value             = self.value
        current_storage[self] = value

        begin
          yield
        ensure
          current_storage[self] = old_value
        end
      end

      def value = storage.store_if_absent(self) { @default_block ? @default_block.call : @default }

      def value=(new_value)
        check_frozen!
        storage[self] = new_value
      end

      private

      def storage = Internal::Storage.scope(@scope)

      def try_shareable(block)
        return block if Ractor.shareable?(block)
        Ractor.shareable_proc(&block)
      rescue StandardError
        block
      end

      define_method(:__freeze__, Kernel.instance_method(:freeze))
    end

    private_constant :LocalVar
  end
end
