# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Unshared
    # @!parse
    #   # A {Reference} for a {Unshared::Lazy} value.
    #   # Delegates to the result after computing it on first access.
    #   # Calling `freeze` resolves and freezes the target.
    #   #
    #   # @example
    #   #   reference = Farce::Unshared::LazyRef.new { [] }
    #   #   reference.push(:ready) # => [:ready]
    #   class LazyRef < Farce::Reference
    #     # @overload initialize(factory)
    #     #   @param factory [Class, Proc, #call] the factory for the lazy value
    #     # @overload initialize(self: nil)
    #     #   @param self [BasicObject] the receiver to bind to the block
    #     #   @yield computes the value on first access
    #     #   @yieldreturn [BasicObject] the computed result
    #     def initialize(...) = nil
    #   end
    LazyRef = Reference[Farce::Unshared::Lazy]
  end
end
