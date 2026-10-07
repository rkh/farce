# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Converter
      class Factory
        class << self
          attr_writer :target_name
        end

        def self.target_name
          return @target_name if defined?(@target_name) && @target_name
          superclass.target_name if superclass.respond_to?(:target_name)
        end

        attr_reader :target_class, :namespace, :options, :converter

        def initialize(converter)
          @converter = converter
          @namespace = converter.namespace
          @options   = converter.options
          @seen      = {}.compare_by_identity

          case target_name = self.class.target_name
          when Symbol, String then @target_class = @namespace.const_get(target_name)
          when Class          then @target_class = target_name
          else raise TypeError, "Unsupported target name: #{target_name.inspect}"
          end
        end

        def convert(value) = @converter.convert(value)

        def convert!(value)
          @seen.fetch(value) do
            instance = @seen[value] = prepare(value)
            apply(instance, value)
            yield instance
            instance
          end
        end

        def prepare(_, **) = @target_class.new(**, **@options)
      end

      REGISTER = ClassMirror.new(Factory)
      private_constant :REGISTER

      def self.define(klass, target_name, &block)
        if block && block.arity != 0
          definition = Internal.prepare_method_definition(&block)
          block      = proc { define_method(:apply, &definition) }
        end
        factory_class             = REGISTER.define(klass, &block)
        factory_class.target_name = target_name
        factory_class
      end

      define(Hash, :Map) do
        def apply(instance, value) = value.each { instance[_1] = convert(_2) }

        def prepare(value, **)
          return super unless value.compare_by_identity?
          super(value, compare_keys_by_identity: true, **)
        end
      end

      define(Array, :Vector) { |instance, value| value.each { instance << convert(it) } }

      define(::Set, :Set) do
        def apply(instance, value) = value.each { instance << convert(it) }

        def prepare(value, **)
          return super unless value.compare_by_identity?
          super(value, compare_by_identity: true, **)
        end
      end

      define(ObjectSpace::WeakMap, :WeakMap) do
        def apply(instance, value) = value.each { instance[_1] = convert(_2) }
        def prepare(value, **) = super(value, compare_keys_by_identity: true, **)
      end

      attr_reader :options, :namespace

      def initialize(namespace, freeze: nil, **options, &callback)
        @namespace = namespace
        @options   = options
        @freeze    = freeze
        @factories = {}
        @callback  = callback
      end

      def convert(value)
        factory_class = REGISTER[value.class]
        return @callback ? @callback.call(value) : value unless factory_class.target_name
        factory = @factories[factory_class] ||= factory_class.new(self)
        factory.convert!(value) do |result|
          result.freeze if @freeze.nil? ? value.frozen? : @freeze
        end
      end
    end
  end
end
