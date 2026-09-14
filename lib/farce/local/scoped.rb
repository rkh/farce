# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Local
    # Common scope selection and storage for shareable local objects.
    module Scoped
      include Shareable

      MANAGER = ModeManager.new
      private_constant :MANAGER

      # @return [Symbol] The scope used to resolve this object's contents.
      attr_reader :scope

      # Constructor arguments configure each scope's independent backing object.
      # @!macro scopes
      # @param arguments [Array<BasicObject>] positional arguments for the backing object
      # @param options [Hash{Symbol => BasicObject}] keyword arguments for the backing object
      # @param scope [Symbol] The storage scope. Defaults to :ractor.
      def initialize(*arguments, scope: :ractor, **options)
        raise ArgumentError, "Invalid scope: #{scope.inspect}" unless Internal::Storage::SCOPES.include?(scope)

        @scope         = scope
        @configuration = MANAGER.wrap([arguments.freeze, options.freeze].freeze)

        Internal::Storage.scope(scope)[self] = new_scoped_value(*arguments, **options) if eager_scoped_value?

        # Abstract initializers allocate instance variables. Local backing objects
        # live in Storage instead, so initialization ends here.
        Ractor.make_shareable(self)
        freeze
      end

      private

      # Subclasses without initial contents can defer backing storage allocation.
      def eager_scoped_value?  = true
      def scoped_configuration = MANAGER.unwrap(@configuration)

      def scoped_value
        Internal::Storage.store_if_absent(self, scope:) do
          arguments, options = scoped_configuration
          new_scoped_value(*arguments, **options)
        end
      end
    end
  end
end
