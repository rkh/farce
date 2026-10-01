# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  class Transaction
    # A {Abstract::Set Set} that is part of a transaction.
    class Set < Abstract::Set
      include SetOperations

      Wrapper.inherit(self, *SetOperations::READ_HELPERS, writes: SetOperations::WRITE_HELPERS)
    end
  end
end
