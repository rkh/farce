# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "delegate"

module Farce
  # Drop-in replacement for Ruby's WeakRef class that is Ractor-friendly.
  #
  # @example
  #   foo = Object.new               # create a new object instance
  #   p foo.to_s                     # original's class
  #   foo = Farce::WeakRef.new(foo)  # reassign foo with WeakRef instance
  #   p foo.to_s                     # should be same class
  #   GC.start                       # start the garbage collector
  #   p foo.to_s                     # should raise exception (recycled)
  class WeakRef < Delegator
    include Internal::MarshalSupport::WeakRef

    recycled = allocate
    recycled.instance_variable_set(:@value, WeakValue::RECYCLED)

    class << recycled
      undef marshal_dump

      # @api private
      def _dump(_) = "recycled"
    end

    # @api private
    RECYCLED = Kernel.instance_method(:freeze).bind_call(recycled)

    # Alias for {WeakRefError} to mimic `::WeakRef::RefError`
    RefError = WeakRefError

    # @api private
    def self._load(state)
      raise TypeError, "invalid weak reference state" unless state == "recycled"
      RECYCLED
    end

    def initialize(value)
      @value = WeakValue.new(value)
      super
      Kernel.instance_method(:freeze).bind_call(self)
    end

    # @api private
    def __getobj__ = @value.value # :nodoc:

    # @api private
    def __setobj__(_) = nil # :nodoc:

    # @return [Boolean] true if the referenced object is still alive and reachable
    def weakref_alive? = @value.alive?

    private

    def respond_to_missing?(name, include_private = false)
      return false if Internal.marshal_protocol_method?(name)
      super
    end

    def initialize_dup(other)       = initialize_copy(other)
    def initialize_clone(other, **) = initialize_copy(other)
  end
end
