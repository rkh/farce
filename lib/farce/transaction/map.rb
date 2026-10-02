# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  class Transaction
    # A {Abstract::ConcurrentMap ConcurrentMap} that is part of a transaction.
    #
    # Reads and writes validate the keys they access, allowing concurrent changes
    # to other keys. Size reads validate cardinality without observing contents.
    # Enumeration, keys, getkey, and clear capture and validate the full map.
    # Staged changes are visible through this wrapper and publish only on commit.
    # Key validation compares current values by identity, not per-key write history.
    # Commit captures a full snapshot for maps accessed by key. Changes after
    # that snapshot is captured can still cause the attempt to fail.
    class Map < Abstract::ConcurrentMap
      include MapOperations

      Wrapper.inherit(self, *MapOperations::READ_HELPERS, :delete_if, :reject!, :compact!, :keep_if,
        :select!, :filter!, :transform_values!, :merge!)

      private def enlist(backend) = @transaction.enlist(backend, per_key: true)
    end
  end
end
