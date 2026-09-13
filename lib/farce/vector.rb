# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A Ractor-shareable vector with transfer modes for mutable values.
  # Values stored through this vector's mode manager are automatically unwrapped.
  #
  # @example Atomically updating a collection
  #   vector = Farce::Vector.new([[]], mode: :make_shareable)
  #   vector.update(0) { |jobs| jobs + [:finished] } # => [:finished]
  class Vector < Farce::Abstract::Vector
    include Shareable

    # @!macro modes
    # @param source [Array, nil] Initial values. The source array is not retained.
    # @param mode [Symbol] The default value transfer mode.
    # @param compare_by_identity [Boolean] Whether values are compared by identity.
    def initialize(source = nil, mode: :copy, compare_by_identity: false)
      raise TypeError, "source must be an Array" unless source.nil? || source.is_a?(Array)
      unless true.equal?(compare_by_identity) || false.equal?(compare_by_identity)
        raise ArgumentError, "compare_by_identity must be true or false"
      end

      @compare_by_identity = compare_by_identity
      @manager = ModeManager.new(mode:)
      @vector = Internal::Vector.new(source&.map { @manager.wrap(it) }, compare_by_identity: true)
      super()
    end

    # @return [Symbol] The default transfer mode.
    def mode = @manager.mode
    def compare_by_identity? = @compare_by_identity
    def shareable_values? = true
    def [](index) = @manager.unwrap(@vector[index])

    def []=(index, value)
      @vector[index] = @manager.wrap(value)
      value
    end

    def get(index, timeout: nil) = @manager.unwrap(@vector.get(index, timeout:))

    # (see Abstract::Vector#store)
    # @param mode [Symbol, nil] The transfer mode, or nil to use the default.
    def store(index, value, mode: nil, timeout: nil)
      @manager.unwrap(@vector.store(index, @manager.wrap(value, mode:), timeout:))
    end

    # (see Abstract::Vector#push)
    # @param mode [Symbol, nil] The transfer mode, or nil to use the default.
    def push(value, mode: nil, timeout: nil)
      @vector.push(@manager.wrap(value, mode:), timeout:) ? self : false
    end

    def pop(timeout: nil) = @manager.unwrap(@vector.pop(timeout:))

    # (see Abstract::Vector#swap)
    # @param mode [Symbol, nil] The replacement's transfer mode, or nil to use the default.
    def swap(index, replacement, mode: nil, timeout: nil)
      @manager.unwrap(@vector.swap(index, @manager.wrap(replacement, mode:), timeout:))
    end

    # (see Abstract::Vector#store_if_absent)
    # @param mode [Symbol, nil] The result's transfer mode, or nil to use the default.
    def store_if_absent(index, mode: nil, timeout: nil)
      raise LocalJumpError, "no block given" unless block_given?
      @manager.unwrap(@vector.store_if_absent(index, timeout:) { @manager.wrap(yield, mode:) })
    end

    # (see Abstract::Vector#update)
    # @param mode [Symbol, nil] The result's transfer mode, or nil to use the default.
    def update(index, mode: nil, timeout: nil)
      raise LocalJumpError, "no block given" unless block_given?
      @manager.unwrap(@vector.update(index, timeout:) { @manager.wrap(yield(@manager.unwrap(it)), mode:) })
    end

    # (see Abstract::Vector#upsert)
    # @param mode [Symbol, nil] The value transfer mode, or nil to use the default.
    def upsert(index, initial, mode: nil, timeout: nil)
      raise LocalJumpError, "no block given" unless block_given?
      @manager.unwrap(@vector.update(index, timeout:) do |current|
        @manager.wrap(nil.equal?(current) ? initial : yield(@manager.unwrap(current)), mode:)
      end)
    end

    # (see Abstract::Vector#compare_and_set)
    # @param mode [Symbol, nil] The replacement's transfer mode, or nil to use the default.
    def compare_and_set(index, expected, replacement, mode: nil, timeout: nil)
      deadline = timeout_deadline(timeout)
      expected = wrap_comparison(expected)
      wrapped = false
      loop do
        current = @vector[index]
        return false unless values_equal?(current, expected)
        unless wrapped
          replacement = @manager.wrap(replacement, mode:)
          wrapped = true
        end
        return true if @vector.compare_and_set(index, current, replacement, timeout: remaining_timeout(deadline))
        return false if nil.equal?(current) || (deadline && Clock.now >= deadline)
      end
    end

    def wait_until_changed(index, expected, timeout: nil)
      deadline = timeout_deadline(timeout)
      expected = wrap_comparison(expected)
      loop do
        current = @vector[index]
        return @manager.unwrap(current) unless values_equal?(current, expected)
        return if deadline && Clock.now >= deadline
        @vector.wait_until_changed(index, current, timeout: remaining_timeout(deadline))
      end
    end

    def wait_until_non_nil(index, timeout: nil) = @manager.unwrap(@vector.wait_until_non_nil(index, timeout:))

    private

    def wrap_comparison(value) = @manager.wrap(value, mode: compare_by_identity? ? :local : :copy)
    def values_equal?(left, right) = @manager.same_value?(left, right, identity: compare_by_identity?)

    def timeout_deadline(timeout)
      return if timeout.nil?
      timeout = Float(timeout)
      raise ArgumentError, "timeout must be finite and non-negative" unless timeout.finite? && !timeout.negative?
      Clock.now + timeout
    end

    def remaining_timeout(deadline)
      return unless deadline
      [deadline - Clock.now, 0].max
    end
  end
end
