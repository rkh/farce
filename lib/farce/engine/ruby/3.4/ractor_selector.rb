# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/ruby/shared/ractor_selector"

module Farce
  module Internal
    class RactorSelector
      # Ruby 3.4's M:N scheduler can strand the helper during Ractor teardown.
      # Keep this helper on a dedicated native thread.
      module DedicatedNativeThread
        private

        def run
          Internal.lock_native_thread
          super
        end
      end
      private_constant :DedicatedNativeThread
      prepend DedicatedNativeThread

      # Native timeout: must retain Ruby's own error even with a scheduler hook.
      # Only Farce's APIs backport that keyword.
      def self.install_hooks(patch)
        patch[::Ractor.singleton_class, :select, signature: "*sources, **options",
          schedule: "*sources, **options", before: "return select!(*sources, **options) if options.key?(:timeout)"]
        patch[::Ractor.singleton_class, :receive, signature: "",
          schedule: "::Ractor.current"]
        patch[::Ractor, :receive, :take, signature: "", schedule: "self"]
      end

      def ractor_receive(source, timeout: nil) = wait([source], timeout)&.at(1)
      alias ractor_take ractor_receive

      def ractor_select(*sources, timeout: nil, yield_value: UNDEFINED, move: false)
        options = { yield_value: yield_value, move: move } unless yield_value.equal?(UNDEFINED)
        raise ArgumentError, "specify at least one Ractor or port" if sources.empty? && !options
        result    = wait(sources, timeout, options)
        result[0] = :receive if result && result[0].equal?(@owner)
        result
      end
      alias select ractor_select

      private

      def receive_source(source) = source

      def fallback_port?(source)
        !source.is_a?(::Ractor) && !source.is_a?(Request) && source.is_a?(Internal::Port)
      end

      def receive_control = @control.take

      def close_control
        @control.close_outgoing
        @control.close_incoming
      end
      alias cleanup_control close_control

      def check_closed(_source); end

      def validate_source(source)
        return if source.is_a?(::Ractor) || source.is_a?(Internal::Port)
        raise ArgumentError, "expected a Ractor or port"
      end

      # A private yielding Ractor makes wakeups selectable on Ruby 3.4.
      # Control traffic stays out of the receiving Ractor's application inbox.
      def build_control
        Fiber.blocking do
          control = ::Ractor.new do
            ::Ractor.yield(nil)
            loop do
              ::Ractor.receive
              ::Ractor.yield(nil)
            end
          rescue ::Ractor::ClosedError
            nil
          ensure
            # No final value is consumed. Close before Ruby publishes it so
            # publication cannot race with the selector closing this port.
            ::Ractor.current.close_outgoing
          end
          # Complete startup before the first command can send a wakeup.
          control.take
          control
        end
      end
    end
  end
end
