# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!parse
  #   # A {Reference} for a {Lazy} value.
  #   #
  #   # Results use the lazy value's transfer mode, which defaults to `:copy`.
  #   #
  #   # Calling `freeze` resolves and freezes the target. Checking `frozen?` before
  #   # the first successful freeze does not resolve it.
  #   #
  #   # @example
  #   #   initialized = Farce::Counter.new
  #   #
  #   #   lazy_ref = Farce::LazyRef.new do
  #   #     initialized.increment
  #   #     Farce::Map.new
  #   #   end
  #   #
  #   #   initialized.value # => 0
  #   #   lazy_ref[:key] = :value
  #   #   initialized.value # => 1
  #   class LazyRef < Farce::Reference
  #     # @!macro modes
  #     # @overload initialize(factory, mode: :copy)
  #     #   @param mode [Symbol] the transfer mode for the computed result
  #     #   @param [Class, Proc, #call] factory The factory to use for creating the value. Must be ractor-shareable.
  #     #
  #     # @overload initialize(self: nil, mode: :copy)
  #     #   @param mode [Symbol] the transfer mode for the computed result
  #     #   @yield The block to use for creating the value. Must be ractor-shareable.
  #     #   @yieldreceiver [BasicObject] The `self` parameter provided, or `nil` if not provided.
  #     #   @yieldreturn [BasicObject] The value to be returned by the lazy instance.
  #     #   @param [BasicObject] self The `self` parameter to be provided to the block. Must be ractor-shareable.
  #     def initialize(...) = nil
  #   end
  LazyRef = Reference[Lazy]
end
