# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# @!group Dry Types Integration
require "farce"
require "dry/types"

module Farce
  module Internal # :nodoc: all
    # Implements the optional dry-types collection import.
    module DryTypes
      # Farce output configuration shared by the imported collection types.
      class Configuration
        VARIANTS = {
          shared:   Farce,
          strict:   Farce::Strict,
          unshared: Farce::Unshared,
          local:    Farce::Local,
        }.freeze
        private_constant :VARIANTS

        # The Farce collection family produced by the imported types.
        # @return [Symbol] :shared, :strict, :unshared, or :local.
        # @api private
        attr_reader :variant

        # The transfer mode for shared collections.
        # @return [Symbol, Object] The selected mode or Farce's undefined sentinel.
        # @api private
        attr_reader :mode

        # The storage scope for local collections.
        # @return [Symbol, Object] The selected scope or Farce's undefined sentinel.
        # @api private
        attr_reader :scope

        # Create validated Farce output configuration.
        # @param variant [Symbol] The Farce collection family to construct.
        # @param mode [Symbol, Object] The shared transfer mode or the undefined sentinel.
        # @param scope [Symbol, Object] The local storage scope or the undefined sentinel.
        # @return [Configuration] The frozen configuration.
        # @api private
        def initialize(variant:, mode: UNDEFINED, scope: UNDEFINED)
          @variant = variant
          @mode    = mode
          @scope   = scope
          validate!
          freeze
        end

        # Resolve the configured Farce collection class.
        # @param kind [Symbol] The lowercase Farce type name.
        # @return [Class] The Farce class for the configured variant.
        # @api private
        def target(kind) = VARIANTS.fetch(variant).const_get(kind.to_s.capitalize, false)

        # Report whether the configured Farce family defines a public type.
        # @param kind [Symbol] The Farce type name in lowercase.
        # @return [Boolean] Whether the variant supports that type.
        # @api private
        def target?(kind) = VARIANTS.fetch(variant).const_defined?(kind.to_s.capitalize, false)

        # Return keywords accepted by the configured Farce constructor.
        # @param kind [Symbol] The Farce value kind being constructed.
        # @return [Hash] The mode or scope keywords for construction.
        # @api private
        def constructor_options(kind)
          case variant
          when :shared
            return {} unless %i[vector map set atom].include?(kind)

            { mode: UNDEFINED.equal?(mode) ? :copy : mode }
          when :local then { scope: UNDEFINED.equal?(scope) ? :ractor : scope }
          else {}
          end
        end

        # Copy the configuration with output options replaced.
        # @param kind [Symbol] The Farce value kind being configured.
        # @param mode [Symbol, Object] The shared transfer mode or the undefined sentinel.
        # @param scope [Symbol, Object] The local storage scope or the undefined sentinel.
        # @return [Configuration] A validated configuration.
        # @api private
        def with(kind:, mode: UNDEFINED, scope: UNDEFINED)
          if %i[counter flag].include?(kind) && !UNDEFINED.equal?(mode)
            raise ArgumentError, "mode is not supported by Farce::#{kind.to_s.capitalize}"
          end

          mode  = @mode  if UNDEFINED.equal?(mode)
          scope = @scope if UNDEFINED.equal?(scope)
          self.class.new(variant:, mode:, scope:)
        end

        private

        def validate!
          unless %i[shared strict unshared local].include?(variant)
            raise ArgumentError, "unknown Farce collection variant: #{variant.inspect}"
          end

          if variant == :shared
            raise ArgumentError, "scope is only supported by the local variant" unless UNDEFINED.equal?(scope)
            raise ArgumentError, "mode :move is not supported by dry-types constructors" if mode == :move
            return if UNDEFINED.equal?(mode) || %i[copy local make_shareable raise shareable_copy].include?(mode)

            raise ArgumentError, "invalid mode: #{mode.inspect}"
          end

          raise ArgumentError, "mode is only supported by the shared variant" unless UNDEFINED.equal?(mode)
          if variant == :local
            selected_scope = UNDEFINED.equal?(scope) ? :ractor : scope
            internal = Farce.const_get(:Internal, false)
            scopes = internal.const_get(:Storage, false).const_get(:SCOPES, false)
            raise ArgumentError, "invalid scope: #{selected_scope.inspect}" unless scopes.include?(selected_scope)
            return
          end
          return if UNDEFINED.equal?(scope)

          raise ArgumentError, "scope is only supported by the local variant"
        end
      end

      # A regular dry type that constructs a Farce value.
      #
      # @!method [](input = Dry::Types::Undefined)
      #   Apply this type using dry-types bracket syntax.
      #   @param input [Object] The input value.
      #   @yield [partial] Handle a coercion or construction failure.
      #   @yieldparam partial [Object] The partial value supplied by dry-types.
      #   @yieldreturn [Object] The fallback returned instead of a Farce value.
      #   @return [Object, nil] The Farce value, nil for an optional type, or the failure block result.
      #
      # @!method ===(input)
      #   Test whether input can produce a valid Farce value.
      #   @param input [Object] The value to test.
      #   @return [Boolean] Whether applying the type succeeds.
      class CollectionType
        include ::Dry::Types::Type
        include ::Dry::Types::Builder

        # The dry type evaluated before Farce construction.
        # @return [Dry::Types::Type] The source type.
        attr_reader :source

        # The Farce value kind produced by this type.
        # @return [Symbol] The lowercase Farce type name.
        # @api private
        attr_reader :kind

        # The Farce output configuration.
        # @return [Configuration] The variant and ownership settings.
        # @api private
        attr_reader :configuration

        # Wrap a dry type with Farce construction.
        # @param source [Dry::Types::Type] The source type.
        # @param kind [Symbol] The lowercase Farce type name.
        # @param configuration [Configuration] The Farce output configuration.
        # @return [CollectionType] The configured dry type.
        # @api private
        def initialize(source, kind:, configuration:)
          @source = source
          @kind = kind
          @configuration = configuration
          @type = DryTypes.build_type(source, kind, configuration)
          freeze
        end

        # Apply validation, coercion, and Farce construction to input.
        # @param input [Object] The input value.
        # @yield [partial] Handle a coercion or construction failure.
        # @yieldparam partial [Object] The partial value supplied by dry-types.
        # @yieldreturn [Object] The fallback returned instead of a Farce value.
        # @return [Object, nil] The Farce value, nil for an optional type, or the failure block result.
        def call(input = ::Dry::Types::Undefined, &) = @type.call(input, &)
        alias [] call

        # Apply the wrapped constructor without a failure callback.
        # @param input [Object] The value to process.
        # @return [Object, nil] The Farce value or nil for an optional type.
        # @api private
        def call_unsafe(input) = @type.call_unsafe(input)

        # Apply the wrapped constructor with dry-types safe-call behavior.
        # @param input [Object] The value to process.
        # @yield [partial] Handle a coercion or construction failure.
        # @yieldparam partial [Object] The partial value supplied by dry-types.
        # @yieldreturn [Object] The fallback result.
        # @return [Object, nil] The Farce value, nil for an optional type, or the failure block result.
        # @api private
        def call_safe(input, &) = @type.call_safe(input, &)

        # Try to construct a Farce value and return a dry-types result.
        # @param input [Object] The value to process.
        # @yield [failure] Handle a failed attempt.
        # @yieldparam failure [Dry::Types::Result::Failure] The failure result.
        # @yieldreturn [Object] The fallback result.
        # @return [Dry::Types::Result, Object] The result or failure block value.
        def try(input, &) = @type.try(input, &)

        # Test whether input can produce a valid Farce value.
        # @param input [Object] The value to test.
        # @return [Boolean] Whether applying the type succeeds.
        def valid?(input = ::Dry::Types::Undefined) = @type.valid?(input)
        alias === valid?

        # Return the output primitive used by a non-optional type.
        # @return [Class] The configured Farce collection class.
        # @api private
        def primitive = @type.primitive

        # Test whether a value is accepted by the output type.
        # @param input [Object] The value to test.
        # @return [Boolean] Whether the value is a configured Farce object or accepted nil.
        def primitive?(input) = @type.primitive?(input)

        # Return the inherited namespace for a non-optional source type.
        # @return [String, nil] The source namespace when one is configured.
        # @api private
        def namespace = @type.namespace

        # Return the output type name.
        # @return [String] The Farce class or optional union name.
        def name = @type.name

        # Report whether this is a default type.
        # @return [Boolean] Whether a default is configured.
        def default? = @type.default?

        # Report whether this type contains constraints.
        # @return [Boolean] Whether constraints are present.
        def constrained? = @type.constrained?

        # Report whether this type accepts nil.
        # @return [Boolean] Whether the type is optional.
        def optional? = @type.optional?

        # Build a successful dry-types result.
        # @param input [Object] The successful value.
        # @return [Dry::Types::Result::Success] The success result.
        # @api private
        def success(input) = @type.success(input)

        # Build a failed dry-types result.
        # @param input [Object] The failed input.
        # @param error [Dry::Types::CoercionError] The coercion error.
        # @return [Dry::Types::Result::Failure] The failure result.
        # @api private
        def failure(input, error) = @type.failure(input, error)

        # Return the dry-types abstract syntax tree.
        # @param meta [Boolean] Whether metadata is included.
        # @return [Array] The type AST.
        def to_ast(meta: true) = @type.to_ast(meta:)

        # Convert this type to a callable object.
        # @return [Proc] A proc that applies the type.
        def to_proc = proc { call(it) }

        # Return the wrapped dry type representation.
        # @return [String] The printable type representation.
        def inspect = @type.inspect

        # Return the dry-types constructor implementation.
        # @return [Class] Dry::Types::Constructor.
        # @api private
        def constructor_type = ::Dry::Types::Constructor

        # Read or extend this type's metadata.
        # @overload meta
        #   @return [Hash] The current metadata.
        # @overload meta(data)
        #   @param data [Hash] Metadata to merge into the source type.
        #   @return [CollectionType] A collection type carrying the metadata.
        def meta(data = ::Dry::Types::Undefined)
          return @type.meta if ::Dry::Types::Undefined.equal?(data)

          self.class.new(source.meta(data), kind:, configuration:)
        end

        # Return a new type without source metadata.
        # @return [CollectionType] A new type with pristine source metadata.
        def pristine = self.class.new(source.pristine, kind:, configuration:)

        # Return a new Farce type with different output or source options.
        # @param mode [Symbol] The transfer mode for the shared variant.
        # @param scope [Symbol] The storage scope for the local variant.
        # @param source_options [Hash] Options forwarded to the source dry type.
        # @return [CollectionType] A new configured type.
        # @raise [ArgumentError] If the Farce type does not support the requested output option.
        def with(mode: UNDEFINED, scope: UNDEFINED, **source_options)
          configured = configuration.with(kind:, mode:, scope:)
          next_source = source_options.empty? ? source : source.with(**source_options)
          self.class.new(next_source, kind:, configuration: configured)
        end

        private

        # Select post-construction constraint behavior.
        # @return [Class] The coercible constrained type class.
        # @api private
        def constrained_type = ::Dry::Types::Constrained::Coercible
      end

      # A Vector or Set type that applies a member type to every input value.
      class SequenceType < CollectionType
        # Apply a dry type to every member before Farce construction.
        # @param member [Dry::Types::Type, #call] The member type.
        # @return [SequenceType] The typed collection.
        def of(member)
          typed = DryTypes.collection_source(source).of(member)
          typed = DryTypes.restore_optional_source(source, typed)
          self.class.new(typed, kind:, configuration:)
        end
      end

      # An Atom type that validates or coerces its initial contents.
      class AtomType < CollectionType
        # Apply a dry type to the initial value before Atom construction.
        #
        # Later writes use the ordinary Farce Atom API and are not checked by
        # this type.
        # @param value_type [Dry::Types::Type] The initial value type.
        # @return [AtomType] A new typed Atom constructor.
        # @raise [ArgumentError] If value_type is not a dry type.
        def of(value_type)
          raise ArgumentError, "Atom.of requires a dry type" unless value_type.is_a?(::Dry::Types::Type)

          self.class.new(value_type, kind:, configuration:)
        end
      end

      # A Map type that supports dry-types homogeneous maps and schemas.
      class MapType < CollectionType
        # Apply dry types to every key and value before Farce construction.
        # @param key_type [Dry::Types::Type] The key type.
        # @param value_type [Dry::Types::Type] The value type.
        # @return [MapType] The homogeneous map type.
        def map(key_type, value_type)
          typed = DryTypes.collection_source(source).map(key_type, value_type)
          typed = DryTypes.restore_optional_source(source, typed)
          self.class.new(typed, kind:, configuration:)
        end

        # Define or extend fixed keys and their dry types before Farce construction.
        # @overload schema(keys_or_map, meta = {})
        #   Create a schema from the imported Hash source.
        #   @param keys_or_map [Hash, Array<Dry::Types::Schema::Key>] The schema definition.
        #   @param meta [Hash] Metadata applied while creating the schema.
        #   @return [MapType] The schema-backed map type.
        # @overload schema(keys_or_map)
        #   Extend an existing schema.
        #   @param keys_or_map [Hash, Array<Dry::Types::Schema::Key>] Additional schema keys.
        #   @return [MapType] The schema-backed map type.
        def schema(...)
          typed = DryTypes.collection_source(source).schema(...)
          typed = DryTypes.restore_optional_source(source, typed)
          self.class.new(typed, kind:, configuration:)
        end

        # Return a schema that rejects unknown keys.
        # @param strict [Boolean] Whether unknown keys are rejected.
        # @return [MapType] The configured map type.
        def strict(strict = true) = rebuild_map_source(:strict, strict) # rubocop:disable Style/OptionalBooleanParameter

        # Transform input keys before schema lookup.
        # @param transform [#call, nil] The key transform.
        # @yield [key] Transform an input key when no callable argument is given.
        # @yieldparam key [Object] An input key.
        # @yieldreturn [Object] The transformed key.
        # @return [MapType] The configured map type.
        def with_key_transform(transform = nil, &) = rebuild_map_source(:with_key_transform, transform, &)

        # Transform schema key types when defining a schema.
        # @param transform [#call, nil] The type transform.
        # @yield [type] Transform a schema key type when no callable argument is given.
        # @yieldparam type [Dry::Types::Schema::Key] A schema key type.
        # @yieldreturn [Dry::Types::Schema::Key] The transformed key type.
        # @return [MapType] The configured map type.
        def with_type_transform(transform = nil, &) = rebuild_map_source(:with_type_transform, transform, &)

        private

        # Explicit arguments avoid losing keyword calls inside JRuby forwarding methods.
        # rubocop:disable-next Style/ArgumentsForwarding
        def rebuild_map_source(method, *arguments, **options, &)
          typed = DryTypes.collection_source(source).public_send(method, *arguments, **options, &)
          typed = DryTypes.restore_optional_source(source, typed)
          self.class.new(typed, kind:, configuration:)
        end
      end

      # Import module installed by Farce.DryTypes().
      class Import < Module
        # Create a deferred Farce dry-types import.
        # @param namespaces [Array<Symbol>] Explicit dry-types namespaces.
        # @param default [Symbol, Object] The default namespace or Farce's undefined sentinel.
        # @param aliases [Hash{Symbol => Symbol}] Dry-types namespace aliases.
        # @param configuration [Configuration] The Farce output configuration.
        # @return [Import] The import module.
        # @api private
        def initialize(namespaces, default:, aliases:, configuration:)
          super()
          @namespaces = namespaces.freeze
          @default = default
          @aliases = aliases.freeze
          @configuration = configuration
        end

        # Install Farce types when this import is included.
        # @param base [Module] The application type module.
        # @return [void]
        # @api private
        def included(base)
          source = source_import(base)
          install_root(base, source)
          install_namespaces(base, source)
          super
        end

        private

        def source_import(base)
          return configured_import if explicitly_configured?

          base.ancestors.find { it.is_a?(::Dry::Types::Module) } || ::Dry.Types()
        end

        def explicitly_configured?
          !@namespaces.empty? || !@aliases.empty? || !UNDEFINED.equal?(@default)
        end

        def configured_import
          if UNDEFINED.equal?(@default)
            ::Dry.Types(*@namespaces, **@aliases)
          else
            ::Dry.Types(*@namespaces, default: @default, **@aliases)
          end
        end

        def install_root(base, source)
          install_collection_constants(base, source)
        end

        def install_namespaces(base, source)
          source.constants(false).each do |name|
            namespace = source.const_get(name, false)
            next unless namespace.is_a?(Module)
            next unless relevant_namespace?(namespace)

            existing = base.const_get(name) if base.const_defined?(name)
            ensure_available!(base, name)
            base.const_set(name, namespace_overlay(namespace, existing))
          end
        end

        def install_collection_constants(target, source)
          if (array = usable_array_type(source))
            install_constant(target, :Vector, SequenceType.new(array, kind: :vector, configuration: @configuration))
            install_constant(target, :Set,    SequenceType.new(array, kind: :set,    configuration: @configuration))
          end
          if (hash = usable_hash_type(source))
            install_constant(target, :Map, MapType.new(hash, kind: :map, configuration: @configuration))
          end
          install_scalar_constants(target, source)
        end

        def install_scalar_constants(target, source)
          if @configuration.target?(:counter) && (integer = usable_type(source, :Integer))
            type = CollectionType.new(integer, kind: :counter, configuration: @configuration)
            install_constant(target, :Counter, type)
          end
          if @configuration.target?(:flag) && (bool = usable_type(source, :Bool))
            install_constant(target, :Flag, CollectionType.new(bool, kind: :flag, configuration: @configuration))
          end
          return unless @configuration.target?(:atom) && dry_namespace?(source)

          any = ::Dry::Types["any"]
          install_constant(target, :Atom, AtomType.new(any, kind: :atom, configuration: @configuration))
        end

        def usable_array_type(source)
          type = source.const_get(:Array, false) if source.const_defined?(:Array, false)
          collection = DryTypes.collection_source(type) if type
          type if valid_source?(collection, ::Array) && collection.respond_to?(:of)
        end

        def usable_hash_type(source)
          type = source.const_get(:Hash, false) if source.const_defined?(:Hash, false)
          collection = DryTypes.collection_source(type) if type
          type if valid_source?(collection, ::Hash) && collection.respond_to?(:map) && collection.respond_to?(:schema)
        end

        def valid_source?(type, primitive)
          return false unless type.is_a?(::Dry::Types::Type) && type.respond_to?(:primitive)

          actual = type.primitive
          actual.is_a?(Class) && actual <= primitive
        end

        def usable_type(source, name)
          type = source.const_get(name, false) if source.const_defined?(name, false)
          type if type.is_a?(::Dry::Types::Type)
        end

        def dry_namespace?(source)
          source.constants(false).any? do |name|
            source.const_get(name, false).is_a?(::Dry::Types::Type)
          end
        end

        def install_constant(target, name, value)
          ensure_available!(target, name)
          target.const_set(name, value)
        end

        def relevant_namespace?(namespace)
          return true if usable_array_type(namespace) || usable_hash_type(namespace)
          return true if scalar_namespace?(namespace)

          namespace.constants(false).any? do |name|
            child = namespace.const_get(name, false)
            child.is_a?(Module) && relevant_namespace?(child)
          end
        end

        def scalar_namespace?(namespace)
          (@configuration.target?(:counter) && usable_type(namespace, :Integer)) ||
            (@configuration.target?(:flag) && usable_type(namespace, :Bool)) ||
            (@configuration.target?(:atom) && dry_namespace?(namespace))
        end

        def namespace_overlay(namespace, existing = nil)
          overlay = Module.new
          overlay.include(namespace)
          overlay.include(existing) if existing.is_a?(Module) && !existing.equal?(namespace)
          install_collection_constants(overlay, namespace)
          namespace.constants(false).each do |name|
            child = namespace.const_get(name, false)
            next unless child.is_a?(Module) && relevant_namespace?(child)

            prior = existing.const_get(name) if existing.is_a?(Module) && existing.const_defined?(name)
            overlay.const_set(name, namespace_overlay(child, prior))
          end
          overlay
        end

        def ensure_available!(target, name)
          return unless target.const_defined?(name, false)

          raise ArgumentError, "cannot import Farce dry type over #{target}::#{name}"
        end
      end

      extend self

      # Create the import module used by Farce.DryTypes().
      # @param namespaces [Array<Symbol>] Explicit dry-types namespaces.
      # @param default [Symbol, Object] The default namespace or Farce's undefined sentinel.
      # @param aliases [Hash{Symbol => Symbol}] Dry-types namespace aliases.
      # @param variant [Symbol] The Farce collection family.
      # @param mode [Symbol, Object] The shared transfer mode or the undefined sentinel.
      # @param scope [Symbol, Object] The local scope or the undefined sentinel.
      # @return [Import] The import module.
      # @api private
      def import(namespaces, default:, aliases:, variant:, mode:, scope:)
        configuration = Configuration.new(variant:, mode:, scope:)
        Import.new(namespaces, default:, aliases:, configuration:)
      end

      # Build the delegated dry constructor for a Farce value.
      # @param source [Dry::Types::Type] The source type.
      # @param kind [Symbol] The lowercase Farce type name.
      # @param configuration [Configuration] The Farce output configuration.
      # @return [Dry::Types::Type] The constructor type.
      # @api private
      def build_type(source, kind, configuration)
        target = configuration.target(kind)
        constructor = lambda do |input, &failure|
          values = source.call(materialize(input, kind), &failure)
          reject_structural_key_collisions!(values) if kind == :map
          optional_nil = kind != :atom && values.nil? && source.optional?
          optional_nil ? nil : target.new(values, **configuration.constructor_options(kind))
        rescue Farce::Ractor::IsolationError, ArgumentError, TypeError, NoMethodError, RangeError => e
          ::Dry::Types::CoercionError.handle(e, &failure)
        end

        output_type(target, source, kind).constructor(constructor)
      end

      # Unwrap the collection branch of an optional source type.
      # @param source [Dry::Types::Type] The possibly optional source.
      # @return [Dry::Types::Type] The Array or Hash branch.
      # @api private
      def collection_source(source)
        source.respond_to?(:optional?) && source.optional? ? source.right : source
      end

      # Restore the nil branch after configuring an optional collection.
      # @param original [Dry::Types::Type] The original source type.
      # @param typed [Dry::Types::Type] The configured collection branch.
      # @return [Dry::Types::Type] The configured type with optionality restored.
      # @api private
      def restore_optional_source(original, typed)
        original.respond_to?(:optional?) && original.optional? ? original.left | typed : typed
      end

      private

      def output_type(target, source, kind)
        type = ::Dry.Types().Nominal(target)
        type = type.with(namespace: source.namespace) if source.respond_to?(:namespace) && source.namespace
        type = type.meta(source.meta) if source.respond_to?(:meta) && !source.meta.empty?
        type = type.constrained(type: target)
        kind != :atom && source.respond_to?(:optional?) && source.optional? ? type.optional : type
      end

      def materialize(input, kind)
        case kind
        when :vector then vector_input(input)
        when :map then map_input(input)
        when :set then materialize_set(input)
        else input
        end
      end

      def vector_input(input)
        return input unless input.is_a?(Farce::Abstract::Vector)

        reject_mode_backed_input!(input)
        input.to_a
      end

      def map_input(input)
        return input unless input.is_a?(Farce::Abstract::Map)

        reject_mode_backed_input!(input)
        input.to_h
      end

      def materialize_set(input)
        if input.is_a?(Farce::Abstract::Set)
          reject_mode_backed_input!(input)
          input.to_a
        elsif input.is_a?(::Set)
          input.to_a
        else
          input
        end
      end

      def reject_mode_backed_input!(input)
        return unless input.respond_to?(:mode)

        raise ArgumentError, "mode-backed Farce collections must be materialized before dry-types processing"
      end

      def reject_structural_key_collisions!(hash)
        return unless hash.is_a?(::Hash) && hash.compare_by_identity?

        structural = {}
        hash.each_key do |key|
          raise ArgumentError, "duplicate structural hash key #{key.inspect}" if structural.key?(key)

          structural[key] = true
        end
      end
    end
  end

  # @note This methods is only available if dry-types has been loaded.
  #
  # Build a dry-types import for Farce types.
  #
  # With no dry namespace options, the import uses the nearest Dry.Types()
  # import already included in the receiving module. Without one, it uses the
  # same strict defaults as Dry.Types(). Dry namespace arguments, `default:`,
  # and aliases select an independent source import using Dry.Types() rules.
  #
  # @param namespaces [Array<Symbol>] Dry type namespaces to import Farce counterparts for.
  # @param default [Symbol] The Dry namespace used for root Farce type constants.
  # @param variant [Symbol] The output variant: :shared, :strict, :unshared, or :local.
  # @param mode [Symbol] The transfer mode for the shared variant.
  # @param scope [Symbol] The storage scope for the local variant.
  # @param aliases [Hash{Symbol => Symbol}] Dry namespace aliases.
  # @return [Module] A module for inclusion beside Dry.Types().
  def self.DryTypes( # rubocop:disable Naming/MethodName
    *namespaces, default: UNDEFINED, variant: :shared, mode: UNDEFINED, scope: UNDEFINED, **aliases
  )
    internal = const_get(:Internal, false).const_get(:DryTypes, false)
    internal.import(namespaces, default:, aliases:, variant:, mode:, scope:)
  end
end
