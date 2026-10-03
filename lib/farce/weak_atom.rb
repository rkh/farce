# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A Ractor-shareable atomic reference that retains its value weakly.
  # Values support :raise (the default), :make_shareable, and :dedup.
  # The value becomes nil after collection when no strong references remain.
  # With :dedup, retain the canonical result returned by store or update.
  # Keeping only the input alive may not keep the stored result alive.
  # Assignment evaluates to the input rather than the canonical result.
  # Comparisons observe the stored object without preparing their operands.
  #
  # @example Publishing the original object without keeping it alive
  #   value = []
  #   atom = Farce::WeakAtom.new(value, mode: :make_shareable)
  #   atom.value.equal?(value) # => true
  #   value = nil
  #   # After collection, atom.value returns nil.
  class WeakAtom < Farce::Abstract::WeakAtom
    include Shareable::Delegated

    TIMED_OUT = Object.new.freeze
    private_constant :TIMED_OUT

    # @param value [BasicObject, nil] the initial value
    # @param mode [Symbol] :raise, :make_shareable, or :dedup
    # @param compare_by_identity [Boolean] whether comparisons use object identity
    def initialize(value = nil, mode: :raise, compare_by_identity: false)
      @manager = Internal::WeakModeManager.new(mode:)
      super(@manager.wrap(value), compare_by_identity:)
    end

    # The default mode used to prepare replacement values.
    # @return [Symbol]
    def mode = @manager.mode

    # (see Abstract::Atom#store)
    # @param mode [Symbol, nil] the replacement's mode, or nil for the default
    def store(new_value, mode: nil, timeout: nil, &)
      check_frozen!
      super(@manager.wrap(new_value, mode:), timeout:, &)
    end

    # (see Abstract::Atom#swap)
    # @param mode [Symbol, nil] the replacement's mode, or nil for the default
    def swap(new_value, mode: nil, timeout: nil, &)
      check_frozen!
      super(@manager.wrap(new_value, mode:), timeout:, &)
    end

    # (see Abstract::Atom#store_if_absent)
    # @param mode [Symbol, nil] the result's mode, or nil for the default
    def store_if_absent(mode: nil, timeout: nil)
      raise LocalJumpError, "no block given" unless block_given?
      @manager.validate_mode!(mode)
      super(timeout:) do
        value = yield
        check_frozen!
        @manager.wrap(value, mode:)
      end
    end

    # (see Abstract::Atom#update)
    # @param mode [Symbol, nil] the result's mode, or nil for the default
    def update(mode: nil, timeout: nil)
      raise LocalJumpError, "no block given" unless block_given?
      @manager.validate_mode!(mode)
      super(timeout:) do |current|
        value = yield(current)
        check_frozen!
        @manager.wrap(value, mode:)
      end
    end

    # (see Abstract::Atom#upsert)
    # @param mode [Symbol, nil] the replacement's mode, or nil for the default
    def upsert(initial, mode: nil, timeout: nil)
      raise LocalJumpError, "no block given" unless block_given?
      @manager.validate_mode!(mode)
      @atom.update(timeout:) do |current|
        value = nil.equal?(current) ? initial : yield(current)
        check_frozen!
        @manager.wrap(value, mode:)
      end
    end

    # (see Abstract::Atom#compare_and_set)
    # @param mode [Symbol, nil] the replacement's mode, or nil for the default
    def compare_and_set(expected, replacement, mode: nil, timeout: nil)
      @manager.validate_mode!(mode)
      matched = false
      @atom.update(timeout:) do |current|
        next current unless values_equal?(current, expected)
        check_frozen!
        prepared = @manager.wrap(replacement, mode:)
        matched = true
        prepared
      end
      matched
    end

    # (see Abstract::Atom#wait_until_changed)
    def wait_until_changed(expected, timeout: nil, &fallback)
      deadline = Internal.timeout_deadline(timeout)
      while true
        current = @atom.get(timeout: Internal.remaining_timeout(deadline)) { TIMED_OUT }
        return fallback&.call if TIMED_OUT.equal?(current)
        return current unless values_equal?(current, expected)
        result = @atom.wait_until_changed(current, timeout: Internal.remaining_timeout(deadline)) { TIMED_OUT }
        return fallback&.call if TIMED_OUT.equal?(result)
      end
    end

    private

    def internal_atom_class = Internal::WeakAtom
    def freeze_backend      = @atom
    def values_equal?(left, right) = @manager.same_value?(left, right, identity: compare_by_identity?)
  end
end
