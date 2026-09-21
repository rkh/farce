# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    module KeyNormalizer
      class CanonicalEntries < Array
      end

      Restoration = Data.define(:value)

      private_constant :CanonicalEntries

      class SymbolNormalizer
        attr_reader :value

        def initialize(method)
          @value = method
          freeze
        end

        def call(key) = key.public_send(@value)
      end

      class ProcNormalizer
        def initialize(callable)
          @callable = callable
          freeze
        end

        def call(key) = @callable.call(key)
      end

      class LookupNormalizer
        attr_reader :source

        def initialize(source)
          @source = source
          freeze
        end

        def call(key) = @source.fetch(key, key)
      end

      module CommonOperations
        private def normalize_key(key) = @key_normalizer.call(key)

        def [](key) = super(normalize_key(key))

        def []=(key, value)
          super(normalize_key(key), value)
        end

        def delete(key) = super(normalize_key(key))
        def getkey(key) = super(normalize_key(key))
        def key?(key)   = super(normalize_key(key))

        def fetch(*arguments)
          return super unless arguments.length.between?(1, 2)

          original, default = arguments
          canonical = normalize_key(original)
          warn "block supersedes default value argument", uplevel: 1 if block_given? && arguments.length == 2
          super(canonical) do
            return yield(original) if block_given?
            return default if arguments.length == 2
            raise KeyError.new("key not found: #{original.inspect}", receiver: self, key: original)
          end
        end
      end

      class ConcurrentMap
        def initialize(map, normalizer)
          @map = map
          @normalizer = normalizer
          Internal::Freeze.publish(self) if Ractor.shareable?(map)
        end

        def freeze
          @map.freeze
          self
        end

        def frozen? = @map.frozen?

        def [](key) = @map[@normalizer.call(key)]

        def []=(key, value)
          @map[@normalizer.call(key)] = value
        end

        def fetch(key, &) = @map.fetch(@normalizer.call(key), &)
        def get(key, ...) = @map.get(@normalizer.call(key), ...)
        def store(key, value, ...) = @map.store(@normalizer.call(key), value, ...)
        def swap(key, value, ...) = @map.swap(@normalizer.call(key), value, ...)
        def store_if_absent(key, ...) = @map.store_if_absent(@normalizer.call(key), ...)

        def compare_and_set(key, expected, replacement, ...)
          @map.compare_and_set(@normalizer.call(key), expected, replacement, ...)
        end

        def update(key, ...)                       = @map.update(@normalizer.call(key), ...)
        def modify(key, ...)                       = @map.modify(@normalizer.call(key), ...)
        def upsert(key, initial, ...)              = @map.upsert(@normalizer.call(key), initial, ...)
        def delete(key)                            = @map.delete(@normalizer.call(key))
        def key?(key)                              = @map.key?(@normalizer.call(key))
        def getkey(key)                            = @map.getkey(@normalizer.call(key))
        def wait_until_changed(key, expected, ...) = @map.wait_until_changed(@normalizer.call(key), expected, ...)
        def wait_until_non_nil(key, ...)           = @map.wait_until_non_nil(@normalizer.call(key), ...)
        def normalize_external_key(key)            = @map.normalize_external_key(@normalizer.call(key))
        def check_mutation                         = @map.check_mutation

        def get_prepared(...)                      = @map.get_prepared(...)
        def store_prepared(...)                    = @map.store_prepared(...)
        def swap_prepared(...)                     = @map.swap_prepared(...)
        def update_prepared(...)                   = @map.update_prepared(...)
        def assignment_prepared(...)               = @map.assignment_prepared(...)
        def wait_until_changed_prepared(...)       = @map.wait_until_changed_prepared(...)
        def size                                   = @map.size
        def keys                                   = @map.keys
        def each(&)                                = @map.each(&)
        def each_live(&)                           = @map.each_live(&)
        def each_key(&)                            = @map.each_key(&)
        def each_value(&)                          = @map.each_value(&)
        def clear                                  = @map.clear
        def compare_keys_by_identity?              = @map.compare_keys_by_identity?
        def compare_values_by_identity?            = @map.compare_values_by_identity?
        def ractor_shareable?                      = Ractor.shareable?(@map)

        def prepare_mutation_key(key)
          @map.check_mutation
          @map.prepare_mutation_key(@normalizer.call(key))
        end
      end

      module ConcurrentBackend
        def self.included(base)
          base.class_eval do
            alias_method :assignment_prepared, :[]=
            alias_method :get_prepared, :get
            alias_method :store_prepared, :store
            alias_method :swap_prepared, :swap
            alias_method :update_prepared, :update
            alias_method :wait_until_changed_prepared, :wait_until_changed
          end
          super
        end

        def normalize_external_key(key)
          if String === key && !key.frozen? && !compare_keys_by_identity?
            key = String.instance_method(:-@).bind_call(key)
          end
          return key if Ractor.shareable?(key)
          raise Ractor::IsolationError, "key must be Ractor-shareable"
        end
      end

      module TreeOperations
        include CommonOperations

        def store_if_absent(key, &) = super(normalize_key(key), &)
      end

      module BoundedOperations
        include CommonOperations

        def store_if_absent(key, &) = super(normalize_key(key), &)
      end

      module LeaseOperations
        include CommonOperations

        def checkout(key, timeout: nil, &)
          canonical = normalize_key(key)
          checkout_canonical(canonical, missing_key: key, timeout:, &)
        end

        def try_checkout(key, &)
          canonical = normalize_key(key)
          try_checkout_canonical(canonical, missing_key: key, &)
        end

        def checkin(key, resource)
          canonical = normalize_key(key)
          checkin_canonical(canonical, resource, missing_key: key)
        end

        def lease_for(key)
          canonical = normalize_key(key)
          lease_for_canonical(canonical, missing_key: key)
        end

        def store_if_absent(key, &) = super(normalize_key(key), &)
        def available?(key)         = super(normalize_key(key))
        def checked_out?(key)       = super(normalize_key(key))
        def owned?(key)             = super(normalize_key(key))
      end

      module_function

      def build(value, shareable:)
        return if value.nil?
        restoring = value.is_a?(Restoration)
        value = value.value if restoring

        normalizer =
          case value
          when Symbol
            SymbolNormalizer.new(value)
          when Proc
            value = Ractor.shareable_proc(&value) if shareable && !Ractor.shareable?(value)
            ProcNormalizer.new(value)
          when Hash, Farce::Abstract::Map
            Ractor.make_shareable(value) if restoring && shareable && !Ractor.shareable?(value)
            if shareable && !Ractor.shareable?(value)
              raise Ractor::IsolationError, "normalizer source must already be Ractor-shareable"
            end
            LookupNormalizer.new(value)
          else
            raise TypeError, "normalizer must be a Symbol, Proc, Hash, or Farce map"
          end

        Ractor.make_shareable(normalizer) if shareable
        normalizer
      end

      def install(target, normalizer, operations)
        return unless normalizer
        target.instance_variable_set(:@key_normalizer, normalizer)
        target.extend(operations)
      end

      def install_concurrent(target, normalizer)
        return unless normalizer
        target.instance_variable_set(:@key_normalizer, normalizer)
        map = target.instance_variable_get(:@map)
        target.instance_variable_set(:@map, ConcurrentMap.new(map, normalizer))
      end

      def prepare_concurrent(map)
        prepare_concurrent_class(map.class)
        map
      end

      def prepare_concurrent_class(type)
        type.include(ConcurrentBackend) unless type < ConcurrentBackend
      end

      def wrap_concurrent(map, normalizer) = normalizer ? ConcurrentMap.new(map, normalizer) : map

      def canonical_entries = CanonicalEntries.new

      def canonical_entries?(entries) = entries.is_a?(CanonicalEntries)

      def restoration?(value) = value.is_a?(Restoration)

      def restore(value) = Restoration.new(value)

      def dump(normalizer)
        case normalizer
        when SymbolNormalizer then normalizer.value
        when LookupNormalizer then normalizer.source
        else raise TypeError, "Proc key normalizers cannot be serialized"
        end
      end

      def operations_for(target)
        case target
        when Farce::Abstract::LeaseMap   then LeaseOperations
        when Farce::Abstract::BoundedMap then BoundedOperations
        when Farce::Abstract::TreeMap    then TreeOperations
        else raise ArgumentError, "concurrent maps use an internal key normalizer"
        end
      end

      def shareable_target?(target)
        target.respond_to?(:ractor_shareable?) ? target.ractor_shareable? : false
      end
    end
  end
end
