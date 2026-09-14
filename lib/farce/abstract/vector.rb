# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract Superclass for concurrent indexed collections.
    # Negative indexes count from the end. Assignments beyond the end fill gaps with nil.
    # Atomic updates reserve the entire vector. Reads through {#[]} do not wait for updates.
    # Timeouts are finite, non-negative seconds. Nil waits indefinitely for access.
    class Vector
      # Read an index without waiting for atomic-update access.
      # @return [BasicObject, nil] The value, or nil for an index outside the vector.
      def [](index) = internal_vector[index]

      # Store a value, growing the vector if necessary.
      # @return [BasicObject] The assigned value.
      def []=(index, value)
        internal_vector[index] = value
      end

      # Read an index after acquiring atomic-update access.
      # @return [BasicObject, nil] The value, or nil if absent or timed out.
      def get(index, timeout: nil) = internal_vector.get(index, timeout:)

      # Store a value after acquiring atomic-update access.
      # @return [BasicObject, false] The value, or false on timeout.
      def store(index, value, timeout: nil) = internal_vector.store(index, value, timeout:)

      # Append a single value.
      # @return [self, false] Self on success, or false on timeout.
      def push(value, timeout: nil)
        internal_vector.push(value, timeout:) ? self : false
      end

      # Append a single value without a timeout.
      # @return [self]
      def <<(value) = push(value)

      # Remove and return the last value.
      # This does not wait for an empty vector to become nonempty.
      # @return [BasicObject, nil] The last value, or nil if empty or timed out.
      def pop(timeout: nil) = internal_vector.pop(timeout:)

      # Replace an index and return its previous value, growing the vector if necessary.
      # @return [BasicObject, nil] The previous value, or nil if absent or timed out.
      def swap(index, replacement, timeout: nil) = internal_vector.swap(index, replacement, timeout:)

      # Compute and store a value only when the index is absent or contains nil.
      # @yieldreturn [BasicObject] The value to store.
      # @return [BasicObject, nil] The existing or computed value, or nil on timeout.
      def store_if_absent(index, timeout: nil, &) = internal_vector.store_if_absent(index, timeout:, &)

      # Replace an existing index only if its value matches the expected value.
      # This never grows the vector. Matching uses the configured comparison mode.
      # @return [Boolean] Whether the replacement succeeded. False on timeout.
      def compare_and_set(index, expected, replacement, timeout: nil)
        internal_vector.compare_and_set(index, expected, replacement, timeout:)
      end

      # Atomically replace an index with the block result, growing the vector if necessary.
      # @yieldparam value [BasicObject, nil] The current value, or nil if absent.
      # @yieldreturn [BasicObject] The replacement value.
      # @return [BasicObject, nil] The replacement value, or nil on timeout.
      def update(index, timeout: nil, &) = internal_vector.update(index, timeout:, &)

      # Store initial for an absent or nil index, otherwise replace it with the block result.
      # @yieldparam value [BasicObject] The current non-nil value.
      # @yieldreturn [BasicObject] The replacement value.
      # @return [BasicObject, nil] The stored value, or nil on timeout.
      def upsert(index, initial, timeout: nil, &) = internal_vector.upsert(index, initial, timeout:, &)

      # Wait until an index no longer matches expected. Absent indexes are observed as nil.
      # @return [BasicObject, nil] The changed value, or nil on timeout.
      def wait_until_changed(index, expected, timeout: nil)
        internal_vector.wait_until_changed(index, expected, timeout:)
      end

      # Wait until an index contains a non-nil value.
      # @return [BasicObject, nil] The non-nil value, or nil on timeout.
      def wait_until_non_nil(index, timeout: nil) = internal_vector.wait_until_non_nil(index, timeout:)

      # @return [Integer] The number of slots, including nil slots.
      def size = internal_vector.size
      alias length size

      # @return [Boolean] Whether there are no slots.
      def empty? = size.zero?

      # @return [Boolean] Whether values are compared by identity.
      def compare_by_identity? = internal_vector.compare_by_identity?

      # @return [Boolean] Whether stored values must be Ractor-shareable.
      def shareable_values? = false

      # Remove all slots.
      # @return [self]
      def clear
        internal_vector.clear
        self
      end

      private def internal_vector = @vector
    end
  end
end
