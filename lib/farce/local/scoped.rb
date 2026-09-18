# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Local
    # Common scope selection and storage for shareable local objects.
    module Scoped
      include Shareable

      module EncodeWith
        # @api private
        # Called by Psych for generating YAML
        def encode_with(coder) = super.tap { it["scope"] = scope }
      end

      module Map
        def initialize(*arguments, normalize_keys: nil, **)
          restoring  = Internal::KeyNormalizer.restoration?(normalize_keys)
          normalizer = Internal::KeyNormalizer.build(normalize_keys, shareable: true)

          if is_a?(Abstract::ConcurrentMap)
            @key_normalizer = normalizer
          else
            Internal::KeyNormalizer.install(self, normalizer, Internal::KeyNormalizer.operations_for(self))
          end

          if normalizer && !restoring && !is_a?(Abstract::LeaseMap) && !arguments.empty? && arguments.first
            entries = arguments.first
            raise TypeError, "initial mapping must be a Hash" if is_a?(Abstract::ConcurrentMap) && !entries.is_a?(Hash)
            entries = convert_entries(entries) if respond_to?(:convert_entries, true)
            canonical = Internal::KeyNormalizer.canonical_entries
            entries.each { |key, value| canonical << [normalizer.call(key), value] }
            arguments = arguments.dup
            arguments[0] = canonical
          end
          super(*arguments, **)
        end
      end

      MANAGER = ModeManager.new
      private_constant :MANAGER, :EncodeWith, :Map

      # @!visibility private
      def self.included(base)
        base.include EncodeWith if base.method_defined?(:encode_with)
        base.include Map        if base < Abstract::Map
        super
      end

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
