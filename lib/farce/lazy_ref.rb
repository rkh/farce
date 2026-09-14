# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!parse
  #   # A {Reference} for a {Lazy} value.
  #   #
  #   # @example
  #   #   initialized = false
  #   #
  #   #   lazy_ref = Farce::LazyRef.new do
  #   #     initialize = true
  #   #     Farce::Map.new
  #   #   end
  #   #
  #   #   initialize # => false
  #   #   lazy_ref[:key] = :value
  #   #   initialized # => true
  #   class LazyRef < Farce::Reference
  #     # @overload initialize(factory)
  #     #   @param [Class, Proc, #call] factory The factory to use for creating the value. Must be ractor-shareable.
  #     #
  #     # @overload initialize(self: nil)
  #     #   @yield The block to use for creating the value. Must be ractor-shareable.
  #     #   @yieldreceiver [BasicObject] The `self` parameter provided, or `nil` if not provided.
  #     #   @yieldreturn [BasicObject] The value to be returned by the lazy instance.
  #     #   @param [BasicObject] self The `self` parameter to be provided to the block. Must be ractor-shareable.
  #     def initialize(...) = nil
  #   end
  LazyRef = Reference[Lazy]
end
