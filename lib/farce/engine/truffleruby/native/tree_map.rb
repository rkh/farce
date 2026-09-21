# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/truffleruby/native/unsafe_tree_map"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Synchronized native-TruffleRuby map. Storage and ordered operations come
    # from UnsafeTreeMap; this subclass adds coordination and guarded mutability.
    class TreeMap < UnsafeTreeMap
      private

      def synchronized?                  = true
      def operation_lock                 = Lock.new
      def ensure_mutation_still_allowed! = Internal::Freeze.check(self)

      def with_map_operation(state, mutation:) # rubocop:disable Lint/UnusedMethodArgument
        current = Fiber.current
        raise ThreadError, "deadlock; recursive tree map access" if
          primitive_identical?(state.operation_owner, current)

        state.lock.synchronize do
          without_async_interrupts { state.operation_owner = current }
          yield
        ensure
          without_async_interrupts do
            state.operation_owner = nil if primitive_identical?(state.operation_owner, current)
          end
        end
      end
    end

    MutableTreeMap = TreeMap

    # No Ractors, no problems :)
    ShareableTreeMap = TreeMap
  end
end
