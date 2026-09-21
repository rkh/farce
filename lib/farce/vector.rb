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
    include Shareable::Delegated

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

    # (see Farce::Abstract::Vector#compare_by_identity?)
    def compare_by_identity? = @compare_by_identity

    # (see Farce::Abstract::Vector#shareable_values?)
    def shareable_values? = true

    # (see Farce::Abstract::Vector#[])
    def [](index) = @manager.unwrap(@vector[index])

    # (see Farce::Abstract::Vector#[]=)
    def []=(index, value)
      check_frozen!
      @vector[index] = @manager.wrap(value)
      value
    end

    # (see Farce::Abstract::Vector#get)
    def get(index, timeout: nil) = @manager.unwrap(@vector.get(index, timeout:))

    # (see Farce::Abstract::Vector#store)
    # @param mode [Symbol, nil] The transfer mode, or nil to use the default.
    def store(index, value, mode: nil, timeout: nil)
      check_frozen!
      @manager.unwrap(@vector.store(index, @manager.wrap(value, mode:), timeout:))
    end

    # (see Farce::Abstract::Vector#push)
    # @param mode [Symbol, nil] The transfer mode, or nil to use the default.
    def push(value, mode: nil, timeout: nil)
      check_frozen!
      @vector.push(@manager.wrap(value, mode:), timeout:) ? self : false
    end

    # (see Farce::Abstract::Vector#pop)
    def pop(timeout: nil) = @manager.unwrap(@vector.pop(timeout:))

    # (see Farce::Abstract::Vector#swap)
    # @!macro modes
    # @param mode [Symbol, nil] The replacement's transfer mode, or nil to use the default.
    def swap(index, replacement, mode: nil, timeout: nil)
      check_frozen!
      @manager.unwrap(@vector.swap(index, @manager.wrap(replacement, mode:), timeout:))
    end

    # (see Farce::Abstract::Vector#store_if_absent)
    # @param mode [Symbol, nil] The result's transfer mode, or nil to use the default.
    def store_if_absent(index, mode: nil, timeout: nil)
      raise LocalJumpError, "no block given" unless block_given?
      check_frozen!
      @manager.unwrap(@vector.store_if_absent(index, timeout:) do
        value = yield
        check_frozen!
        @manager.wrap(value, mode:)
      end)
    end

    # (see Farce::Abstract::Vector#update)
    # @!macro modes
    # @param mode [Symbol, nil] The result's transfer mode, or nil to use the default.
    def update(index, mode: nil, timeout: nil)
      raise LocalJumpError, "no block given" unless block_given?
      check_frozen!
      @manager.unwrap(@vector.update(index, timeout:) do |current|
        value = yield(@manager.unwrap(current))
        check_frozen!
        @manager.wrap(value, mode:)
      end)
    end

    # (see Farce::Abstract::Vector#upsert)
    # @!macro modes
    # @param mode [Symbol, nil] The value transfer mode, or nil to use the default.
    def upsert(index, initial, mode: nil, timeout: nil)
      raise LocalJumpError, "no block given" unless block_given?
      check_frozen!
      @manager.unwrap(@vector.update(index, timeout:) do |current|
        value = if nil.equal?(current)
                  initial
                else
                  yielded = yield(@manager.unwrap(current))
                  check_frozen!
                  yielded
                end
        @manager.wrap(value, mode:)
      end)
    end

    # (see Farce::Abstract::Vector#compare_and_set)
    # @!macro modes
    # @param mode [Symbol, nil] The replacement's transfer mode, or nil to use the default.
    def compare_and_set(index, expected, replacement, mode: nil, timeout: nil)
      check_frozen!
      deadline = timeout_deadline(timeout)
      expected = wrap_comparison(expected)
      wrapped = false
      loop do
        current = @vector[index]
        equal   = values_equal?(current, expected)
        check_frozen!
        return false unless equal
        unless wrapped
          replacement = @manager.wrap(replacement, mode:)
          wrapped = true
        end
        return true if @vector.compare_and_set(index, current, replacement, timeout: remaining_timeout(deadline))
        return false if nil.equal?(current) || (deadline && Clock.now >= deadline)
      end
    end

    # (see Farce::Abstract::Vector#wait_until_changed)
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

    # (see Farce::Abstract::Vector#wait_until_non_nil)
    def wait_until_non_nil(index, timeout: nil) = @manager.unwrap(@vector.wait_until_non_nil(index, timeout:))

    private

    def freeze_backend             = @vector
    def wrap_comparison(value)     = @manager.wrap(value, mode: compare_by_identity? ? :local : :copy)
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
