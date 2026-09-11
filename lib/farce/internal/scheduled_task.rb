# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal # :nodoc: all
    # A shareable task and its transferred arguments.
    class ScheduledTask
      include Shareable

      MANAGER = ModeManager.new

      def initialize(args, block, mode)
        @block  = Ractor.shareable_proc(&block)
        @unwrap = false
        @args   = args.map! do |arg|
          wrapped = MANAGER.wrap(arg, mode:)
          @unwrap = true if MANAGER.managed_envelope?(wrapped)
          wrapped
        end.freeze
        super()
      end

      def to_proc(completion = nil)
        if completion
          if @unwrap
            lambda do
              @block.call(*@args.map { |arg| MANAGER.unwrap(arg) })
            ensure
              completion.task_finished
            end
          else
            lambda do
              @block.call(*@args)
            ensure
              completion.task_finished
            end
          end
        elsif @unwrap
          -> { @block.call(*@args.map { |arg| MANAGER.unwrap(arg) }) }
        else
          -> { @block.call(*@args) }
        end
      end
    end
  end
end
