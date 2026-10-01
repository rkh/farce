# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  class Transaction
    # A {Abstract::SortedSet SortedSet} that is part of a transaction.
    class SortedSet < Abstract::SortedSet
      include SetOperations

      Wrapper.inherit(self, *SetOperations::READ_HELPERS, :ordered_keys, writes: SetOperations::WRITE_HELPERS)

      # SortedSet builds temporary membership indexes for comparisons. Use the
      # participant's map factory to retain support for mutable Local keys.
      private def new_map(...) = @object.method(:new_map).call(...)
    end
  end
end
