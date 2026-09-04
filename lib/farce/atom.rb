# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A Ractor-shareable atomic reference that can hold non-shareable values.
  #
  # Values are transferred according to the atom's default {#mode}, or an operation-specific mode where supported.
  # Values returned by the atom are automatically unwrapped. Updates are serialized, and comparison operations compare
  # the stored values without claiming or opening their envelopes when possible.
  class Atom
    include Shareable
    include Abstract::Value

    NIL_VALUE = Object.new.freeze
    TIMED_OUT = Object.new.freeze
    private_constant :NIL_VALUE, :TIMED_OUT

    # @!macro modes
    # @param value [BasicObject, nil] the initial value
    # @param compare_by_identity [Boolean] whether comparisons use object identity instead of equality
    # @param mode [Symbol] the default mode used to transfer values between Ractors
    def initialize(value = nil, compare_by_identity: false, mode: :copy)
      unless compare_by_identity == true || compare_by_identity == false
        raise ArgumentError, "compare_by_identity must be a boolean"
      end

      @manager             = ModeManager.new(mode:)
      @compare_by_identity = compare_by_identity
      @atom                = Internal::Atom.new(wrap_value(value), compare_by_identity: true)
      super()
    end

    # The default mode used to transfer values between Ractors.
    # @return [Symbol]
    def mode = @manager.mode

    # Whether comparisons use object identity instead of equality.
    # @return [Boolean]
    def compare_by_identity? = @compare_by_identity

    # Return the current value without waiting for an update in progress.
    # @return [BasicObject, nil] the current value
    def value = unwrap_value(@atom.value)

    # Store a value using the default mode.
    # @param new_value [BasicObject, nil] the new value
    # @return [BasicObject, nil] the new value
    def value=(new_value)
      store(new_value)
    end

    # Return the current value, waiting for any update in progress.
    # @param timeout [Numeric, nil] the maximum number of seconds to wait
    # @yield called when the timeout expires
    # @return [BasicObject, nil] the current value or the fallback result
    def get(timeout: nil, &) = unwrap_result(@atom.get(timeout:) { TIMED_OUT }, &)

    # Store a new value, waiting for any update in progress.
    # @!macro modes
    # @param new_value [BasicObject, nil] the new value
    # @param mode [Symbol, nil] the transfer mode, or nil to use the atom's default mode
    # @param timeout [Numeric, nil] the maximum number of seconds to wait
    # @yield called when the timeout expires
    # @return [BasicObject, nil] the stored value or the fallback result
    def store(new_value, mode: nil, timeout: nil, &)
      new_value = wrap_value(new_value, mode:)
      unwrap_result(@atom.store(new_value, timeout:) { TIMED_OUT }, &)
    end

    # Replace the current value and return the previous value.
    # @!macro modes
    # @param new_value [BasicObject, nil] the new value
    # @param mode [Symbol, nil] the transfer mode, or nil to use the atom's default mode
    # @param timeout [Numeric, nil] the maximum number of seconds to wait
    # @yield called when the timeout expires
    # @return [BasicObject, nil] the previous value or the fallback result
    def swap(new_value, mode: nil, timeout: nil, &)
      new_value = wrap_value(new_value, mode:)
      unwrap_result(@atom.swap(new_value, timeout:) { TIMED_OUT }, &)
    end

    # Compute and store a value if the current value is nil.
    # @!macro modes
    # @param mode [Symbol, nil] the transfer mode, or nil to use the atom's default mode
    # @param timeout [Numeric, nil] the maximum number of seconds to wait
    # @yield computes the value to store when the current value is nil
    # @yieldreturn [BasicObject, nil] the value to store
    # @return [BasicObject, nil] the current or newly stored value, or nil when the timeout expires
    def store_if_absent(mode: nil, timeout: nil)
      raise LocalJumpError, "no block given" unless block_given?

      result = @atom.update(timeout:) do |current|
        NIL_VALUE.equal?(current) ? wrap_value(yield, mode:) : current
      end
      unwrap_value(result)
    end

    # Atomically replace the current value if it matches the expected value.
    # @!macro modes
    # @param expected [BasicObject, nil] the value to compare with the current value
    # @param new_value [BasicObject, nil] the replacement value
    # @param mode [Symbol, nil] the replacement's transfer mode, or nil to use the atom's default mode
    # @param timeout [Numeric, nil] the maximum number of seconds to wait
    # @return [Boolean] whether the value was replaced
    def compare_and_set(expected, new_value, mode: nil, timeout: nil)
      expected = wrap_comparison(expected)
      matched  = false

      @atom.update(timeout:) do |current|
        next current unless values_equal?(current, expected)

        matched = true
        wrap_value(new_value, mode:)
      end
      matched
    end

    # Atomically replace the current value with the result of a block.
    # @!macro modes
    # @param mode [Symbol, nil] the result's transfer mode, or nil to use the atom's default mode
    # @param timeout [Numeric, nil] the maximum number of seconds to wait
    # @yield receives the current value and computes its replacement
    # @yieldparam current [BasicObject, nil] the current value
    # @yieldreturn [BasicObject, nil] the replacement value
    # @return [BasicObject, nil] the replacement value, or nil when the timeout expires
    def update(mode: nil, timeout: nil)
      raise LocalJumpError, "no block given" unless block_given?
      result = @atom.update(timeout:) { |current| wrap_value(yield(unwrap_value(current)), mode:) }
      unwrap_value(result)
    end

    # Store an initial value if the current value is nil, otherwise replace it with the result of a block.
    # @!macro modes
    # @param initial_value [BasicObject, nil] the value to store when the current value is nil
    # @param mode [Symbol, nil] the transfer mode, or nil to use the atom's default mode
    # @param timeout [Numeric, nil] the maximum number of seconds to wait
    # @yield receives a non-nil current value and computes its replacement
    # @yieldparam current [BasicObject] the current value
    # @yieldreturn [BasicObject, nil] the replacement value
    # @return [BasicObject, nil] the current replacement or initial value, or nil when the timeout expires
    def upsert(initial_value, mode: nil, timeout: nil)
      raise LocalJumpError, "no block given" unless block_given?

      result = @atom.update(timeout:) do |current|
        if NIL_VALUE.equal?(current)
          wrap_value(initial_value, mode:)
        else
          wrap_value(yield(unwrap_value(current)), mode:)
        end
      end
      unwrap_value(result)
    end

    # Wait until the current value no longer matches an expected value.
    # @param expected [BasicObject, nil] the value to compare with the current value
    # @param timeout [Numeric, nil] the maximum number of seconds to wait
    # @yield called when the timeout expires
    # @return [BasicObject, nil] the changed value or the fallback result
    def wait_until_changed(expected, timeout: nil, &)
      expected = wrap_comparison(expected)
      deadline = timeout_deadline(timeout)

      loop do
        current = @atom.get(timeout: remaining_timeout(deadline)) { TIMED_OUT }
        return unwrap_result(current, &) if TIMED_OUT.equal?(current)
        return unwrap_value(current) unless values_equal?(current, expected)

        result = @atom.wait_until_changed(current, timeout: remaining_timeout(deadline)) { TIMED_OUT }
        return unwrap_result(result, &) if TIMED_OUT.equal?(result)
      end
    end

    # Wait until the current value is not nil.
    # @param timeout [Numeric, nil] the maximum number of seconds to wait
    # @yield called when the timeout expires
    # @return [BasicObject, nil] the non-nil value or the fallback result
    def wait_until_non_nil(timeout: nil, &) = wait_until_changed(nil, timeout:, &)

    private

    def wrap_value(value, mode: nil)
      value.nil? ? NIL_VALUE : @manager.wrap(value, mode:)
    end

    def wrap_comparison(value)
      mode = compare_by_identity? ? :local : :copy
      wrap_value(value, mode:)
    end

    def unwrap_value(value)
      return if NIL_VALUE.equal?(value)

      @manager.unwrap(value)
    end

    def unwrap_result(result)
      return unwrap_value(result) unless TIMED_OUT.equal?(result)

      yield if block_given?
    end

    def values_equal?(left, right) = @manager.same_value?(left, right, identity: compare_by_identity?)

    def timeout_deadline(timeout)
      return unless timeout

      timeout = Float(timeout)
      raise ArgumentError, "timeout must be non-negative" if timeout.negative?
      raise ArgumentError, "timeout must be finite"       if timeout.infinite?
      raise ArgumentError, "timeout must be a number"     if timeout.nan?

      Clock.now + timeout
    end

    def remaining_timeout(deadline)
      return unless deadline

      remaining = deadline - Clock.now
      remaining.positive? ? remaining : 0
    end
  end
end
