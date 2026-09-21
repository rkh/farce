# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Coordinate equal keys without retaining entries after an operation finishes.
    class KeyLockMap
      include Freeze::Unfreezable

      def initialize(registry_class:, **comparison_options)
        @registry = registry_class.new(**comparison_options)
        Freeze.publish(self) if @registry.ractor_shareable?
      end

      def synchronize(key)
        raise LocalJumpError, "no block given" unless block_given?

        completed = Object.new
        catch(completed) do
          # Nonlocal exit releases the reservation without publishing a value.
          # The block result stays with the caller, even for shareable registries.
          @registry.store_if_absent(key) { throw completed, yield }
        end
      end
    end
  end
end
