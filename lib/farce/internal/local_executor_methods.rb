# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal # :nodoc: all
    # The local scheduling and execution interface for Ractor-local executors.
    module LocalExecutorMethods
      LOCAL_MODES = %i[local smart smart_raise smart_move smart_copy].freeze
      private_constant :LOCAL_MODES

      # @param wait [Boolean] Accepted for compatibility with {Abstract::Executor#local?}.
      # @return [true] Workers run in the calling Ractor.
      def local?(wait: true) = true # rubocop:disable Lint/UnusedMethodArgument

      # Run a task directly, preserving its block, arguments, and calling fiber.
      # `mode` and `auto_local` follow the same validation as {#schedule}.
      # @param (see Abstract::Executor#execute)
      # @return [self, nil]
      def execute(*, mode: :smart, auto_local: true, timeout: nil, &)
        validate_local_mode(mode, auto_local)
        super(*, mode: :local, auto_local: true, timeout:, &)
      end

      private

      def validate_local_mode(mode, auto_local)
        return if auto_local || LOCAL_MODES.include?(mode)
        raise ArgumentError, "only local or smart modes are supported"
      end
    end
  end
end
