# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A weak value is similar to a {WeakRef}, but does not delegate method calls to the referenced object.
  # If a weak value is created for a shareable object, it will also be shareable.
  # If {#freeze} is called, the referenced object will be made shareable (unless it has been garbage collected).
  #
  # @example
  #   object = Object.new
  #   weak   = Farce::WeakValue.new(object)
  #   weak.value == object # => true
  #   weak.alive?          # => true
  #
  #   # Shareability traversal
  #   Ractor.shareable?(object) # => false
  #   Ractor.shareable?(weak)   # => false
  #
  #   Ractor.make_shareable(weak)
  #   Ractor.shareable?(weak)   # => true
  #   Ractor.shareable?(object) # => true
  #
  #   # lets assume that the object has been garbage collected
  #   object = nil
  #   GC.start
  #
  #   weak.alive? # => false
  #   weak.value # WeakRefError: Invalid Reference - probably recycled
  class WeakValue
    include Abstract::Value

    MOVED = Object.new.freeze
    private_constant :MOVED

    nil_value = new

    class << nil_value
      def dup               = self
      def clone(**)         = self
      def value             = nil
      def alive?            = true
      def moved?            = false
      def ractor_shareable? = true

      private

      def _value          = nil
      def state_and_value = [:alive, nil]
    end

    nil_value.instance_variable_set(:@mutex, nil)

    NIL_VALUE = nil_value.freeze
    private_constant :NIL_VALUE

    # @param (see #initialize)
    # @return [WeakValue] a new weak value wrapping the given object
    # @see #initialize
    def self.new(value) = value.nil? ? NIL_VALUE : super

    # @param value [Object] the object to be weakly referenced
    def initialize(value)
      if Ractor.shareable?(value)
        @atom  = Strict::WeakAtom.new(value)
        @mutex = nil
      else
        @atom  = Unshared::WeakAtom.new(value)
        @mutex = Mutex.new
      end
    end

    # Copies share the weak reference without copying its target.
    # @return [Boolean] true
    def duplicable? = true

    # Checks whether the referenced object has avoided garbage collection and has not been moved.
    # @return [Boolean] true if the weak value is still alive, false otherwise
    def alive?
      !_value.nil?
    rescue Ractor::MovedError
      false
    end

    # Freezes the weak value, making the referenced object shareable if it is still alive.
    # Can be called after the value has been garbage collected or moved.
    # Will raise however if the referenced object is still alive and cannot be made shareable.
    # @return [self] the frozen weak value
    def freeze
      @mutex&.synchronize do
        return self if frozen?
        value = begin
          Ractor.make_shareable(_value)
        rescue Ractor::MovedError
          MOVED
        end
        @atom  = Strict::WeakAtom.new(value)
        @mutex = nil
      end
      super
    end

    # Checks if the referenced object has been moved to another Ractor.
    # @return [Boolean] true if the referenced object has been moved, false otherwise
    def moved?
      Ractor::MovedObject === _value
    rescue Ractor::MovedError
      true
    end

    # @return [Boolean] true if the referenced object is shareable by Ractor, false otherwise
    def ractor_shareable?
      return false unless Ractor.shareable?(_value)
      freeze && true
    rescue Ractor::MovedError
      freeze && true
    end

    # Retrieves the referenced object if it is still alive and has not been moved.
    # Raises if it is no longer reachable.
    # @return [BasicObject] the referenced object if it is still alive and has not been moved
    # @raise [WeakRefError] if the referenced object is no longer reachable or has been moved
    def value
      value = _value
      raise WeakRefError, "Invalid Reference - probably recycled" if value.nil?
      value
    rescue Ractor::MovedError
      raise WeakRefError, "Invalid Reference - referenced object has been moved"
    end

    # @return [String] a string representation of the weak value
    def inspect
      state, value = state_and_value
      "#<#{self.class.name} state=#{state.inspect}#{" value=#{value.inspect}" if state == :alive}>"
    end

    # @api private
    # @return [void]
    # simplecov:disable
    def pretty_print(pp)
      state, value = state_and_value
      pp.group(1, "#<#{self.class.name}", ">") do
        pp.breakable " "
        pp.text "state="
        pp.pp(state)
        if state == :alive
          pp.breakable " "
          pp.text "value="
          pp.pp(value)
        end
      end
    end
    # simplecov:enable

    private

    def initialize_clone(other, freeze: nil)
      super
      self.freeze if freeze == true
    end

    def _value
      value = @atom.value
      raise Ractor::MovedError, "referenced object has been moved" if MOVED.equal?(value)
      value
    end

    def state_and_value
      value = _value
      return :recycled if value.nil?
      [:alive, value]
    rescue Ractor::MovedError
      :moved
    end
  end
end
