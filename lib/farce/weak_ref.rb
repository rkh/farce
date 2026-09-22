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
    # Alias for {WeakRefError} to mimic `::WeakRef::RefError`
    RefError = WeakRefError

    def initialize(value)
      @value = WeakValue.new(value)
      super
    end

    # @api private
    def __getobj__ = @value.value # :nodoc:

    # @api private
    def __setobj__(_) = nil # :nodoc:

    # @return [Boolean] true if the referenced object is still alive and reachable
    def weakref_alive? = @value.alive?

    private

    def initialize_dup(other)       = initialize_copy(other)
    def initialize_clone(other, **) = initialize_copy(other)
  end
end
