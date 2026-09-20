# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Local
    # A shareable lazy value computed once per scope. Results may be mutable.
    class Lazy < Abstract::Lazy
      include Scoped

      # @!macro scopes
      # @overload initialize(factory, scope: :ractor)
      #   @param factory [Class, Proc, #call] a shareable factory for each scope's value
      #   @param scope [Symbol] the scope of the lazy value
      # @overload initialize(scope: :ractor, self: nil)
      #   @param scope [Symbol] the scope of the lazy value
      #   @param self [BasicObject] the shareable receiver to bind to the block
      #   @yield computes the value on first access in each scope
      #   @yieldreceiver [BasicObject] the self parameter, or nil if omitted
      #   @yieldreturn [BasicObject] the initial value for the scope, which may be mutable
      # @return [Lazy]
      def initialize(factory = nil, scope: :ractor, **, &)
        @factory   = prepare_factory(factory, **, &)
        @state_key = Object.new.freeze
        super(scope:)
      end

      private

      def eager_scoped_value? = false
      def internal_atom       = Internal::Storage.store_if_absent(@state_key, scope:) { new_scoped_value }
      def new_scoped_value    = Internal::UnsharedAtom.new
    end
  end
end
