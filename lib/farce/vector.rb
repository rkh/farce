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
  #
  # @!method append(*values, mode: nil, timeout: nil)
  #   Append values using the same options as {#push}.
  #   @param values [Array<BasicObject>] The values to append.
  #   @param mode [Symbol, nil] The transfer mode, or nil to use the default.
  #   @param timeout [Numeric, nil] The maximum wait in seconds. Nil waits indefinitely.
  #   @return [self, false] Self on success, or false on timeout.
  class Vector < Farce::Abstract::Vector
    include Shareable::Delegated

    # @!macro modes
    # @param source [Array, Integer, nil] Initial values or a size filled with nil. The source array is not retained.
    # @param mode [Symbol] The default value transfer mode.
    # @param compare_by_identity [Boolean] Whether values are compared by identity.
    # @raise [ArgumentError] If the size is negative.
    def initialize(source = nil, mode: :smart, compare_by_identity: false)
      source = normalize_vector_source(source)
      raise TypeError, "source must be an Array" unless source.nil? || source.is_a?(Array)
      unless true.equal?(compare_by_identity) || false.equal?(compare_by_identity)
        raise ArgumentError, "compare_by_identity must be true or false"
      end

      @compare_by_identity = compare_by_identity
      @manager = ModeManager.new(mode:)
      @vector = Internal::Vector.new(source&.map { @manager.wrap(it) }, compare_by_identity: true)
      super()
    end

    # @api private
    def transaction_wrapper(transaction) = Transaction::Vector.new(transaction, self, @vector, manager: @manager)

    # @return [Symbol] The default transfer mode.
    def mode = @manager.mode

    # @api private
    def marshal_dump
      entries = @vector.snapshot.map { Internal::MarshalSupport.value(it) }
      [1, entries, @manager, compare_by_identity?, frozen?]
    end

    # @api private
    def marshal_load(data)
      entries, @manager, identity, frozen = Internal::MarshalSupport.payload(data, 4)
      @compare_by_identity = identity
      @vector = Internal::Vector.new(compare_by_identity: true)
      publish_shareable
      entries.each { @vector.push(Internal::MarshalSupport.restore_value(it)) }
      Internal::MarshalSupport.freeze(self, frozen)
    end

    # (see Farce::Abstract::Vector#compare_by_identity?)
    def compare_by_identity? = @compare_by_identity

    # (see Farce::Abstract::Vector#shareable_values?)
    def shareable_values? = true

    # (see Farce::Abstract::Vector#[])
    def [](index, length = UNDEFINED)
      return @manager.unwrap(@vector[index]) if length.equal?(UNDEFINED) && !index.is_a?(Range)
      slice(index, length)
    end

    # (see Farce::Abstract::Vector#[]=)
    def []=(index, value, replacement = UNDEFINED)
      if replacement.equal?(UNDEFINED) && !index.is_a?(Range)
        check_frozen!
        @vector[index] = @manager.wrap(value)
        value
      else
        assign_vector_slice(index, value, replacement)
      end
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
    def push(value = UNDEFINED, *rest, mode: nil, timeout: nil)
      if rest.empty? && !value.equal?(UNDEFINED)
        check_frozen!
        stored = mode.nil? ? @manager.wrap(value) : @manager.wrap(value, mode:)
        completed = timeout.nil? ? @vector.push(stored) : @vector.push(stored, timeout:)
        return completed ? self : false
      end
      push_values(value.equal?(UNDEFINED) ? rest : [value, *rest], mode:, timeout:)
    end

    # (see Farce::Abstract::Vector#pop)
    def pop(count = UNDEFINED, timeout: nil)
      return @manager.unwrap(timeout.nil? ? @vector.pop : @vector.pop(timeout:)) if count.equal?(UNDEFINED)
      pop_values(count, timeout:)
    end

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
        return true if @vector.compare_and_set(index, current, replacement, timeout: Clock.remaining(deadline))
        return false if nil.equal?(current) || (deadline && Clock.now >= deadline)
      end
    end

    # (see Farce::Abstract::Vector#wait_until)
    def wait_until(index, timeout: nil)
      raise LocalJumpError, "no block given" unless block_given?
      result = Internal.wait_until(@vector, index, timeout:) { |current| yield(@manager.unwrap(current)) }
      @manager.unwrap(result)
    end

    # (see Farce::Abstract::Vector#wait_until_changed)
    def wait_until_changed(index, expected, timeout: nil)
      deadline = timeout_deadline(timeout)
      expected = wrap_comparison(expected)
      loop do
        current = @vector[index]
        return @manager.unwrap(current) unless values_equal?(current, expected)
        return if deadline && Clock.now >= deadline
        @vector.wait_until_changed(index, current, timeout: Clock.remaining(deadline))
      end
    end

    # (see Farce::Abstract::Vector#wait_until_non_nil)
    def wait_until_non_nil(index, timeout: nil) = @manager.unwrap(@vector.wait_until_non_nil(index, timeout:))

    protected

    def logical_value(value)              = @manager.unwrap(value)
    def deletion_comparison(value)        = wrap_comparison(value)
    def deletion_match?(stored, expected) = values_equal?(stored, expected)

    def build_derived_vector(values)
      self.class.allocate.initialize_derived_vector(values, @manager, @compare_by_identity)
    end

    def initialize_derived_vector(values, manager, compare_by_identity)
      @manager = manager
      @compare_by_identity = compare_by_identity
      @vector = Internal::Vector.new(values, compare_by_identity: true)
      publish_shareable
    end

    attr_reader :manager

    def reusable_operand_snapshot(other)
      return unless other.is_a?(Farce::Vector)
      return unless other.manager.equal?(@manager)
      other.internal_vector.snapshot
    end

    private

    def inspect_value(inspector, value)        = super(inspector, value, @manager)
    def derived_storage(value)                 = @manager.wrap(value)
    def prepare_vector_value(value, mode: nil) = @manager.wrap(value, mode:)

    # Expanded descendants have no independent envelope to reuse. Copy them rather than
    # moving them out of a retained parent Array or another sequence's storage.
    def prepare_sequence_value(value)
      @manager.wrap(value, mode: mode == :move ? :copy : nil)
    end

    def freeze_backend             = @vector
    def wrap_comparison(value)     = @manager.wrap(value, mode: compare_by_identity? ? :local : :copy)
    def values_equal?(left, right) = @manager.same_value?(left, right, identity: compare_by_identity?)

    def timeout_deadline(timeout)
      return if timeout.nil?
      timeout = Float(timeout)
      raise ArgumentError, "timeout must be finite and non-negative" unless timeout.finite? && !timeout.negative?
      Clock.now + timeout
    end
  end
end
