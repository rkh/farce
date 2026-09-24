# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal # :nodoc: all
    class MainThreadScheduler < ThreadScheduler
      # Enter the main emulated Ractor without starting another thread.
      def execute(...) = FakeRactor.with_current(Ractor.main) { super }
      def local?(wait: true) = Ractor.main? # rubocop:disable Lint/UnusedMethodArgument
    end

    MainScheduler = MainThreadScheduler.new do |*args, &block|
      Thread.new do
        ThreadGroup::Default.add(Thread.current)
        block.call(*args)
      end
    end
  end
end
