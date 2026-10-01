# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  class Transaction
    # A {Abstract::ConcurrentMap ConcurrentMap} that is part of a transaction.
    class Map < Abstract::ConcurrentMap
      include MapOperations

      Wrapper.inherit(self, *MapOperations::READ_HELPERS, :delete_if, :reject!, :compact!, :keep_if,
        :select!, :filter!, :transform_values!, :merge!)
    end
  end
end
