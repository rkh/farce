# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract Common interface and behavior for atomic references.
    #
    # Concrete implementations decide how values are retained and transferred.
    # A value may become `nil` without an explicit update when an implementation
    # retains it weakly.
    class Atom
      include Value

      # Whether comparisons use object identity instead of equality.
      # @return [Boolean]
      def compare_by_identity? = internal_atom.compare_by_identity?

      # Return the current value without waiting for an update in progress.
      # @return [BasicObject, nil] the current value
      def value = internal_atom.value

      # Store a new value.
      # @param new_value [BasicObject, nil] the new value
      # @return [BasicObject, nil] the new value
      def value=(new_value)
        store(new_value)
      end

      # Return the current value, waiting for any update in progress.
      # @param timeout [Numeric, nil] the maximum number of seconds to wait
      # @yield called when the timeout expires
      # @return [BasicObject, nil] the current value or the fallback result
      def get(timeout: nil, &) = internal_atom.get(timeout:, &)

      # Store a new value, waiting for any update in progress.
      # @param new_value [BasicObject, nil] the new value
      # @param timeout [Numeric, nil] the maximum number of seconds to wait
      # @yield called when the timeout expires
      # @return [BasicObject, nil] the stored value or the fallback result
      def store(new_value, timeout: nil, &) = internal_atom.store(new_value, timeout:, &)

      # Replace the current value and return the previous value.
      # @param new_value [BasicObject, nil] the new value
      # @param timeout [Numeric, nil] the maximum number of seconds to wait
      # @yield called when the timeout expires
      # @return [BasicObject, nil] the previous value or the fallback result
      def swap(new_value, timeout: nil, &) = internal_atom.swap(new_value, timeout:, &)

      # Compute and store a value if the current value is nil.
      # @param timeout [Numeric, nil] the maximum number of seconds to wait
      # @yield computes the value to store when the current value is nil
      # @yieldreturn [BasicObject, nil] the value to store
      # @return [BasicObject, nil] the current or newly stored value, or nil when the timeout expires
      def store_if_absent(timeout: nil, &) = internal_atom.store_if_absent(timeout:, &)

      # Atomically replace the current value if it matches the expected value.
      # @param expected [BasicObject, nil] the value to compare with the current value
      # @param new_value [BasicObject, nil] the replacement value
      # @param timeout [Numeric, nil] the maximum number of seconds to wait
      # @return [Boolean] whether the value was replaced
      def compare_and_set(expected, new_value, timeout: nil)
        internal_atom.compare_and_set(expected, new_value, timeout:)
      end

      # Atomically replace the current value with the result of a block.
      # @param timeout [Numeric, nil] the maximum number of seconds to wait
      # @yield receives the current value and computes its replacement
      # @yieldparam current [BasicObject, nil] the current value
      # @yieldreturn [BasicObject, nil] the replacement value
      # @return [BasicObject, nil] the replacement value, or nil when the timeout expires
      def update(timeout: nil, &) = internal_atom.update(timeout:, &)

      # Store an initial value if the current value is nil, otherwise replace it with the result of a block.
      # @param initial_value [BasicObject, nil] the value to store when the current value is nil
      # @param timeout [Numeric, nil] the maximum number of seconds to wait
      # @yield receives a non-nil current value and computes its replacement
      # @yieldparam current [BasicObject] the current value
      # @yieldreturn [BasicObject, nil] the replacement value
      # @return [BasicObject, nil] the replacement or initial value, or nil when the timeout expires
      def upsert(initial_value, timeout: nil, &) = internal_atom.upsert(initial_value, timeout:, &)

      # Wait until the current value no longer matches an expected value.
      # @param expected [BasicObject, nil] the value to compare with the current value
      # @param timeout [Numeric, nil] the maximum number of seconds to wait
      # @yield called when the timeout expires
      # @return [BasicObject, nil] the changed value or the fallback result
      def wait_until_changed(expected, timeout: nil, &)
        internal_atom.wait_until_changed(expected, timeout:, &)
      end

      # Wait until the current value is not nil.
      # @param timeout [Numeric, nil] the maximum number of seconds to wait
      # @yield called when the timeout expires
      # @return [BasicObject, nil] the non-nil value or the fallback result
      def wait_until_non_nil(timeout: nil, &) = internal_atom.wait_until_non_nil(timeout:, &)
      private def internal_atom = @atom
    end
  end
end
