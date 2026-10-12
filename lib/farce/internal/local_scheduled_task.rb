# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal # :nodoc: all
    # A Ractor-local task that retains its block and argument references.
    class LocalScheduledTask
      include Noncopyable
      include Farce::Unshareable

      def initialize(args, block)
        @args  = args
        @block = block
        super()
      end

      def to_proc(completion = nil)
        lambda do
          @block.call(*@args)
        ensure
          completion&.task_finished
        end
      end
    end
  end
end
