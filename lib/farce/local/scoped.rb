# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Local
    # Common scope selection and storage for shareable local objects.
    module Scoped
      include Shareable

      # Freeze the current backing before recording the handle-global state.
      # @api private
      module Tracked
        include Scoped

        # @!visibility private
        def self.included(base)
          Scoped.included(base)
          super
        end

        def freeze
          return Object.instance_method(:freeze).bind_call(self) unless @farce_freeze_state

          state = @farce_freeze_state
          if state.respond_to?(:native_flag)
            state.set { freeze_scoped_value(scoped_value) }
            self
          else
            freeze_scoped_value(scoped_value)
            super
          end
        end

        private

        def scoped_value
          value = super
          freeze_scoped_value(value) if frozen?
          value
        end
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

          if !is_a?(Abstract::LeaseMap) && !arguments.empty?
            entries = convert_entries(arguments.first)
            if entries && ((normalizer && !restoring) || !entries.is_a?(Hash))
              canonical = Internal::KeyNormalizer.canonical_entries
              entries.each do |key, value|
                key = normalizer.call(key) if normalizer && !restoring
                canonical << [key, value]
              end
              entries = canonical
            end
            arguments = arguments.dup
            arguments[0] = entries
          end
          super(*arguments, **)
        end

        private

        def install_copied_map(map)      = Internal::Storage.scope(scope)[self] = new_copied_scoped_value(map)
        def new_copied_scoped_value(map) = map
      end

      MANAGER = ModeManager.new
      private_constant :MANAGER, :Map

      # @!visibility private
      def self.included(base)
        base.include Map if base < Abstract::Map
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
        initialize_scoped(arguments, options, scope:)
      end

      private

      def initialize_scoped(arguments, options, scope:, configuration: nil)
        raise ArgumentError, "Invalid scope: #{scope.inspect}" unless Farce::SCOPES.include?(scope)

        if is_a?(Shareable::Tracked)
          guard = Internal.native_ractors? ? Internal::TransactionFreezeGuard : Internal::Flag
          @farce_freeze_state = guard.new(false)
        end
        @scope         = scope
        @configuration = configuration || MANAGER.wrap([arguments.freeze, options.freeze].freeze)

        Internal::Storage.scope(scope)[self] = new_scoped_value(*arguments, **options) if eager_scoped_value?

        # Abstract initializers allocate instance variables. Local backing objects
        # live in Storage instead, so initialization ends here.
        Internal::Freeze.publish(self)
      end

      def marshal_configuration
        value = Envelope === @configuration ? @configuration.marshal_dump[1] : @configuration
        arguments, options = value
        canonical = Internal::KeyNormalizer.canonical_entries?(arguments.first)
        if canonical
          arguments = arguments.dup
          arguments[0] = arguments[0].to_a.freeze
          value = [arguments.freeze, options].freeze
        end
        [Internal::MarshalSupport.value(value), canonical]
      end

      # @api private
      def marshal_initialize(arguments, options, configuration)
        options = options.dup
        scope = options.delete(:scope)
        if options.key?(:normalize_keys)
          normalizer = Internal::KeyNormalizer.build(options.delete(:normalize_keys), shareable: true)
          if is_a?(Abstract::ConcurrentMap)
            @key_normalizer = normalizer
          else
            Internal::KeyNormalizer.install(self, normalizer, Internal::KeyNormalizer.operations_for(self))
          end
        end
        original, canonical = configuration
        original = Internal::MarshalSupport.restore_value(original)
        if canonical
          initial, settings = original
          initial = initial.dup
          initial[0] = Internal::KeyNormalizer.canonical_entries.concat(initial[0])
          original = [initial.freeze, settings].freeze
        end
        configuration = MANAGER.wrap(original)
        initialize_scoped(arguments, options, scope:, configuration:)
      end

      # Subclasses without initial contents can defer backing storage allocation.
      def eager_scoped_value? = true
      def freeze_scoped_value(value) = value.freeze
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
