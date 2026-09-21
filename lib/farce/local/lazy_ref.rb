# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Local
    # @!parse
    #   # A {Reference} for a {Lazy Local::Lazy} value.
    #   # Freezing affects the current scope's target. Afterward, `frozen?` reflects
    #   # the current target and may initialize it when entering another scope.
    #   #
    #   # @example
    #   #   # Delegate to a Ractor-local hash
    #   #   lazy_ref = Farce::Local::LazyRef.new { {} }
    #   #
    #   #   lazy_ref[:key] = :value
    #   #   lazy_ref[:key] # => :value
    #   #
    #   #   Ractor.new(lazy_ref) do |lazy_ref|
    #   #     lazy_ref[:key] # => nil
    #   #   end
    #   class LazyRef < Farce::Reference
    #     # @overload initialize(factory, scope: :ractor)
    #     #   @param [Class, Proc, #call] factory The factory to use for creating the value. Must be ractor-shareable.
    #     #   @param scope [Symbol] the scope of the lazy value
    #     #
    #     # @overload initialize(self: nil, scope: :ractor)
    #     #   @yield The block to use for creating the value. Must be ractor-shareable.
    #     #   @yieldreceiver [BasicObject] The `self` parameter provided, or `nil` if not provided.
    #     #   @yieldreturn [BasicObject] The value to be returned by the lazy instance.
    #     #   @param [BasicObject] self The `self` parameter to be provided to the block. Must be ractor-shareable.
    #     #   @param scope [Symbol] the scope of the lazy value
    #   end
    LazyRef = Reference[Farce::Local::Lazy]
  end
end
