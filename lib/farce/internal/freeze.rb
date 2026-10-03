# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal
    # Shared implementation for the explicit frozen-state policies in {Shareable}.
    module Freeze
      # Structurally freeze a Ruby facade, then validate and publish its object graph.
      # This deliberately bypasses an override that controls logical frozen state.
      def self.publish(object)
        Object.instance_method(:freeze).bind_call(object)
        ::Ractor.make_shareable(object) if Internal.native_ractors?
        object
      end

      def self.check(object)
        return object unless object.frozen?

        raise FrozenError.new("can't modify frozen #{object.class}", receiver: object)
      end

      # Delegate logical frozen state to storage owned by the wrapper.
      module Delegated
        def freeze
          backend = freeze_backend
          raise "#{self.class} is not initialized" unless backend

          backend.freeze
          self
        end

        def frozen?
          backend = freeze_backend
          backend ? backend.frozen? : Object.instance_method(:frozen?).bind_call(self)
        end

        private

        def check_frozen! = Internal::Freeze.check(self)

        def publish_shareable_copy(other, operation:, freeze: nil)
          logically_frozen = operation == :clone && (freeze.nil? ? other.frozen? : freeze)
          self.freeze if logically_frozen
          publish_shareable
        end
      end

      # Track one logical frozen state shared by all storage resolved through a facade.
      module Tracked
        def initialize(...)
          @farce_freeze_state = Internal::Flag.new(false)
          super
        end

        def freeze
          @farce_freeze_state.set
          self
        end

        def frozen?
          state = @farce_freeze_state
          state ? state.value : Object.instance_method(:frozen?).bind_call(self)
        end

        private

        def check_frozen! = Internal::Freeze.check(self)

        def initialize_copy(other, **)
          super
          state = other.instance_variable_get(:@farce_freeze_state)
          guard = state.respond_to?(:native_flag) ? state.class : Internal::Flag
          @farce_freeze_state = guard.new(false)
        end

        def publish_shareable_copy(other, operation:, freeze: nil)
          logically_frozen = operation == :clone && (freeze.nil? ? other.frozen? : freeze)
          self.freeze if logically_frozen
          publish_shareable
        end
      end

      # Keep a live service structurally published while rejecting logical freezing.
      module Unfreezable
        def freeze = raise(TypeError, "#{self.class} cannot be frozen")
        def frozen? = false

        private

        def publish_shareable_copy(_other, operation:, freeze: nil)
          self.freeze if operation == :clone && freeze == true
          publish_shareable
        end
      end

      # Let a purpose-built native object publish itself after payload initialization.
      module Native
        private

        def publish_shareable = self

        def publish_shareable_copy(other, operation:, freeze: nil)
          logically_frozen = operation == :clone && (freeze.nil? ? other.frozen? : freeze)
          self.freeze if logically_frozen
          publish_shareable
        end
      end

      # Keep ordinary Ruby frozen state as the public state.
      module Immutable
        private

        def publish_shareable_copy(*) = publish_shareable
      end
    end
  end
end
