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
      def transaction_snapshot
        state = initialized_state
        entries, revision = with_map_operation(state, mutation: false) do
          [state.entries.map { Entry.new(it.key, it.value) }, state.revision]
        end
        working = self.class.new
        working.instance_variable_get(:@state).instance_variable_set(:@entries, entries)
        PortableTransaction::TreeEntry.new(self, working, revision, state.lock, :@entries)
      end

      private

      def synchronized?                  = true
      def operation_lock                 = Lock.new
      def ensure_mutation_still_allowed! = Internal::Freeze.check(self)

      def with_map_operation(state, mutation:)
        current = Fiber.current
        raise ThreadError, "deadlock; recursive tree map access" if
          primitive_identical?(state.operation_owner, current)

        state.lock.synchronize do
          ensure_mutation_still_allowed! if mutation
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
