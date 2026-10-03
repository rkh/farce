# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Strict
    # @!parse
    #   # A {Reference} for a {Strict::Lazy} value.
    #   # Delegates to the result after computing it on first access.
    #   # Calling `freeze` resolves and freezes the target.
    #   #
    #   # @example
    #   #   reference = Farce::Strict::LazyRef.new { [:ready].freeze }
    #   #   reference.first # => :ready
    #   class LazyRef < Farce::Reference
    #     # @overload initialize(factory)
    #     #   @param factory [Class, Proc, #call] the factory for the lazy value, which must be shareable
    #     # @overload initialize(self: nil)
    #     #   @param self [BasicObject] the receiver to bind to the block, which must be shareable
    #     #   @yield computes the value on first access
    #     #   @yieldreturn [BasicObject] the computed result
    #     def initialize(...) = nil
    #   end
    LazyRef = Reference[Farce::Strict::Lazy]
  end
end
