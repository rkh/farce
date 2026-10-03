# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Unshared
    # A thread-safe lazy value within one Ractor.
    # Its factory may capture mutable state. The result retains its identity.
    # Factory failures can be retried on the next access.
    #
    # @example Build a mutable cache on first access
    #   lazy = Farce::Unshared::Lazy.new { {} }
    #   lazy.value[:job] = :ready
    #
    # @!parse
    #   class Lazy < Abstract::Lazy
    #     # Without `self:`, the block keeps its original receiver.
    #     # @overload initialize(factory)
    #     #   @param factory [Class, Proc, #call] the factory, which may retain mutable state
    #     # @overload initialize(self: nil)
    #     #   @param self [BasicObject] the receiver to bind to the block
    #     #   @yield computes the value on first access, preserving captured state
    #     #   @yieldreturn [BasicObject] the cached result
    #     def initialize(...) = nil
    #   end
    class Lazy < Abstract::Lazy
      include Unshareable

      private

      def new_internal_atom = Internal::UnsharedAtom.new

      def prepare_proc(factory, **options)
        options.empty? ? factory : Farce.rebind(factory, **options)
      end
    end
  end
end
