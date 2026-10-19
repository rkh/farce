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

      # (see Abstract::ConcurrentMap#store_if_present)
      # @param mode [Symbol, nil] The result's transfer mode, or nil to use the default.
      def store_if_present(key, mode: nil)
        require_block!(block_given?)
        write do
          canonical = prepare(key)
          next unless @working.key?(canonical)
          replacement = yield(unwrap_stored(@working[canonical]))
          unwrap_stored(store_value(canonical, wrap(replacement, mode:)))
        end
      end

      # (see Abstract::ConcurrentMap#replace_if_exists)
      # @param mode [Symbol, nil] The replacement's transfer mode, or nil to use the default.
      def replace_if_exists(key, replacement, mode: nil)
        write do
          canonical = prepare(key)
          next unless @working.key?(canonical)
          previous = @working[canonical]
          store_value(canonical, wrap(replacement, mode:))
          unwrap_stored(previous)
        end
      end

      # (see Abstract::ConcurrentMap#delete_pair)
      # A failed comparison invalidates the transaction attempt.
      def delete_pair(key, expected)
        removed = modify_entry(key) do |present, value|
          present && values_equal?(value, expected) ? Internal::MAP_DELETE : Internal::MAP_KEEP
        end
        compared(removed)
      end

      Wrapper.inherit(self, *MapOperations::READ_HELPERS, :delete_if, :reject!, :compact!, :keep_if,
        :select!, :filter!, :transform_values!, :merge!, :put, :get_and_set, :compute_if_absent,
        :compute_if_present, :replace_pair, :compute, :merge_pair, :fetch_or_store, :put_if_absent)

      private def enlist(backend) = @transaction.enlist(backend, per_key: true)
    end
  end
end
