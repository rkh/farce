# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract Common boolean interface and serialization for atomic flags.
    # @note This is a module rather than a class so {Farce::Flag} can inherit
    #   directly from the native flag and avoid delegation overhead.
    #
    # @!method value
    #   @return [Boolean] the current value
    #
    # @!method set
    #   Set the flag to true.
    #   @return [true]
    #
    # @!method unset
    #   Set the flag to false.
    #   @return [false]
    #
    # @!method store(value)
    #   Set the flag to the given value.
    #   @param value [Boolean] the new value
    #   @return [Boolean] the new value
    #   @raise [ArgumentError] if the value is not true or false
    #
    # @!method value=(value)
    #   Alias for {#store}
    #
    # @!method swap(value)
    #   Replace the value and return its previous state.
    #   @param value [Boolean] the new value
    #   @return [Boolean] the previous value
    #   @raise [ArgumentError] if the value is not true or false
    #
    # @!method compare_and_set(expected_value, replacement_value)
    #   Replace the value only if it matches the expected value.
    #   @param expected_value [Boolean] the expected current value
    #   @param replacement_value [Boolean] the new value
    #   @return [Boolean] whether the replacement succeeded
    #   @raise [ArgumentError] if either argument is not true or false
    #
    # @!method wait_until_changed(expected, timeout: nil)
    #   Wait until the current value differs from the expected value.
    #   @param expected [Boolean] the value to wait to change from
    #   @param timeout [Numeric, nil] the total seconds available
    #   @yield called when the timeout expires
    #   @return [Boolean, BasicObject, nil] the changed value or timeout fallback
    #   @raise [ArgumentError] if expected is not true or false
    #
    # @!method toggle
    #   Atomically invert the value.
    #   @return [Boolean] the new value
    module Flag
      include Internal::MarshalSupport::Flag
      include Internal::Copyable
      include Value
      include Internal::ValueSerialization
      include Internal::Inspect

      # @return [Boolean] whether the flag is set
      def set? = value

      # @return [Boolean] whether the flag is unset
      def unset? = !value

      # Wait until the flag becomes true.
      # @param timeout [Numeric, nil] the total seconds available
      # @yield called when the timeout expires
      # @return [Boolean, BasicObject, nil] the changed value or timeout fallback
      def wait_until_set(timeout: nil, &) = wait_until_changed(false, timeout:, &)
      alias wait_until_true  wait_until_set
      alias wait_while_unset wait_until_set
      alias wait_while_false wait_until_set

      # Wait until the flag becomes false.
      # @param timeout [Numeric, nil] the total seconds available
      # @yield called when the timeout expires
      # @return [Boolean, BasicObject, nil] the changed value or timeout fallback
      def wait_until_unset(timeout: nil, &) = wait_until_changed(true, timeout:, &)
      alias wait_until_false wait_until_unset
      alias wait_while_set   wait_until_unset
      alias wait_while_true  wait_until_unset

      # Wait until a block condition matches the current value.
      # One timeout budget covers all checks and waits. The block is not interrupted.
      # @yieldparam value [Boolean] the current value
      # @yieldreturn [Boolean] whether the value matches
      # @param timeout [Numeric, nil] the total seconds available
      # @return [Boolean, nil] the matching value, or nil on timeout
      # @raise [LocalJumpError] if no block is given
      def wait_until(timeout: nil, &) = Internal.wait_until(self, timeout:, &)

      # Wait while the block returns a truthy value.
      # @yieldparam value [Boolean] the current value
      # @yieldreturn [BasicObject] a truthy value to keep waiting, or nil or false to stop
      # @param timeout [Numeric, nil] the total seconds available
      # @return [Boolean, nil] the value when the condition becomes false, or nil on timeout
      # @raise [LocalJumpError] if no block is given
      def wait_while(timeout: nil)
        raise LocalJumpError, "no block given" unless block_given?
        wait_until(timeout:) { |value| !yield(value) }
      end

      # Wait while `object === value` is true.
      # @param object [#===] the pattern to stop matching
      # @param timeout [Numeric, nil] the total seconds available
      # @return [Boolean, nil] the first nonmatching value, or nil on timeout
      def wait_while_match(object, timeout: nil)
        wait_while(timeout:) { |value| object === value } # rubocop:disable Style/CaseEquality
      end

      # (see #wait_until_changed)
      def wait_while_value(...) = wait_until_changed(...)

      # Wait until `object == value` is true.
      # @param object [BasicObject] the value to compare with the current value
      # @param timeout [Numeric, nil] the total seconds available
      # @return [Boolean, nil] the matching value, or nil on timeout
      def wait_until_value(object, timeout: nil)
        wait_until(timeout:) { |value| object == value }
      end

      # Wait until `object === value` is true.
      # @param object [#===] the pattern to match
      # @param timeout [Numeric, nil] the total seconds available
      # @return [Boolean, nil] the matching value, or nil on timeout
      def wait_until_match(object, timeout: nil)
        wait_until(timeout:) { |value| object === value } # rubocop:disable Style/CaseEquality
      end

      # @api private
      def inspect_with(inspector)
        begin
          current = value
        rescue StandardError
          # FrozenError may inspect an allocated flag before it is initialized.
          return inspector.object_with_address(self)
        end

        super do
          yield if block_given?
          inspector.breakable
          inspector.object(current)
        end
      end
    end
  end
end
