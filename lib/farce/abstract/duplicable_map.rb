# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # Map operations that return independent maps of the same kind.
    # Include this in subclasses of {Map} that support copying.
    # Operations work on an independent copy, not an atomic snapshot of the source.
    # Local copies transform the current scope and retain constructor defaults for other scopes.
    module DuplicableMap
      # Return an independent map containing only the requested keys that exist.
      # @param keys [Array<BasicObject>] keys to retain, using the map's lookup rules
      # @return [Map] A map of the same class with the same settings.
      def slice(*keys)
        with_map_copy do |_, map|
          retained = {}.compare_by_identity
          keys.each do |key|
            key = normalize_copied_key(key)
            retained[map.getkey(key)] = true if map.key?(key)
          end
          # Tree backends expose each, but not each_key.
          map.each { |key, _| map.delete(key) unless retained.key?(key) } # rubocop:disable Style/HashEachMethods
        end
      end

      # Return an independent map without the requested keys.
      # @param keys [Array<BasicObject>] keys to omit, using the map's lookup rules
      # @return [Map] A map of the same class with the same settings.
      def except(*keys)
        with_map_copy do |_, map|
          keys.each { map.delete(normalize_copied_key(it)) }
        end
      end

      # Return an independent map without entries whose value is nil. False values are retained.
      # @return [Map] A map of the same class with the same settings.
      def compact
        with_map_copy do |copy, map|
          nil_value = copy.wrap_value(nil)
          map.each { |key, value| map.delete(key) if nil_value.equal?(value) }
        end
      end

      # Return an independent map containing entries accepted by the block.
      # The block receives public values from the copy. Stored values and map settings are preserved.
      # @yieldparam key [BasicObject] an existing key
      # @yieldparam value [BasicObject] the public value
      # @return [Map, Enumerator] A map of the same class, or an Enumerator without a block.
      def select
        return enum_for(__method__) { size } unless block_given?
        with_map_copy do |copy, map|
          map.each { |key, value| map.delete(key) unless yield(key, copy.unwrap_value(value)) }
        end
      end
      alias filter select

      # Return an independent map excluding entries accepted by the block.
      # The block receives public values from the copy. Stored values and map settings are preserved.
      # @yieldparam key [BasicObject] an existing key
      # @yieldparam value [BasicObject] the public value
      # @return [Map, Enumerator] A map of the same class, or an Enumerator without a block.
      def reject
        return enum_for(__method__) { size } unless block_given?
        with_map_copy do |copy, map|
          map.each { |key, value| map.delete(key) if yield(key, copy.unwrap_value(value)) }
        end
      end

      # Return an independent map with transformed keys and unchanged stored values.
      # Mapping entries take precedence over the block. Unmapped keys are retained when no block is given.
      # Transformed keys pass through this map's normalizer. On collisions, the last visited entry wins.
      # Bounded copies rebuild eviction history as transformed entries are inserted.
      # @param mapping [Hash, #to_hash] optional replacements for existing keys
      # @yieldparam key [BasicObject] an existing key
      # @yieldreturn [BasicObject] the replacement key
      # @return [Map, Enumerator] A map of the same class, or an Enumerator without a mapping or block.
      def transform_keys(mapping = UNDEFINED)
        if UNDEFINED.equal?(mapping)
          return enum_for(__method__, mapping) { size } unless block_given?
          mapping = nil
        else
          mapping = Hash.try_convert(mapping) || raise(TypeError, "mapping must be a Hash or respond to #to_hash")
        end

        with_map_copy(empty: true) do |_, map|
          internal_map.each do |key, value|
            if mapping&.key?(key)
              key = normalize_copied_key(mapping.fetch(key))
            elsif block_given?
              key = normalize_copied_key(yield(key))
            end
            map[key] = value
          end
        end
      end

      # Return an independent map with transformed values and unchanged keys.
      # Results follow the map's transfer mode. Move-mode results are copied before transfer to preserve the source.
      # Bounded copies count replacements as writes. The source's eviction history is unchanged.
      # @yieldparam value [BasicObject] the current value
      # @yieldreturn [BasicObject] the replacement value
      # @return [Map, Enumerator] A map of the same class, or an Enumerator without a block.
      def transform_values
        return enum_for(__method__) { size } unless block_given?
        copier = ModeManager.new(mode: :copy) if respond_to?(:mode) && mode == :move
        with_map_copy do |copy, map|
          map.each do |key, value|
            value = yield copy.unwrap_value(value)
            value = copier.unwrap(copier.wrap(value)) if copier
            map[key] = copy.wrap_value(value)
          end
        end
      end

      # Return an independent map with keys and values exchanged.
      # New keys follow the map's normal key normalization and shareability rules.
      # On collisions, the last visited entry wins. Bounded copies rebuild eviction history.
      # @return [Map] A map of the same class with the same settings.
      # @raise [Ractor::IsolationError] if a new key violates the map's shareability rules
      def invert
        copier = ModeManager.new(mode: :copy) if respond_to?(:mode) && mode == :move
        empty_copy.tap do |copy|
          each_pair do |key, value|
            key = copier.unwrap(copier.wrap(key)) if copier
            copy[value] = key
          end
        end
      end

      # Return an independent map with entries from each input applied in order.
      # Incoming keys pass through the normalizer. A block resolves collisions using the canonical key.
      # Move-mode values are copied before transfer to preserve the source and inputs.
      # Bounded copies retain eviction history and apply their usual capacity limits to new writes.
      # @param others [Array<Map, Hash, #to_hash>] maps to merge, with later entries taking precedence
      # @yieldparam key [BasicObject] the canonical key shared by both maps
      # @yieldparam old_value [BasicObject] the current value in the result
      # @yieldparam new_value [BasicObject] the incoming value
      # @yieldreturn [BasicObject] the replacement value
      # @return [Map] A map of the same class with the same settings.
      def merge(*others)
        copier = ModeManager.new(mode: :copy) if respond_to?(:mode) && mode == :move
        with_map_copy do |copy, map|
          others.each do |other|
            unless Map === other
              other = Hash.try_convert(other) || raise(TypeError, "input must be a Map, Hash, or respond to #to_hash")
            end
            other.each_pair do |key, value|
              key = normalize_copied_key(key)
              value = yield(key, copy.unwrap_value(map[key]), value) if block_given? && map.key?(key)
              value = copier.unwrap(copier.wrap(value)) if copier
              map[key] = copy.wrap_value(value)
            end
          end
        end
      end

      # Return a lambda that looks up a key using this map's current contents and lookup rules.
      # The lambda is Ractor-shareable when this map is Ractor-shareable.
      # @return [Proc] A one-argument lookup lambda.
      def to_proc
        lookup = ->(key) { self[key] }
        Ractor.shareable?(self) ? Ractor.shareable_lambda(self: self, &lookup) : lookup
      end

      # Return keys and values in a flattened Array.
      # The default depth flattens entry pairs. Zero preserves pairs, and negative depths flatten all levels.
      # @param level [Integer, #to_int] the number of Array levels to flatten
      # @return [Array] The flattened entries.
      def flatten(level = 1)
        level = Integer.try_convert(level) || raise(TypeError, "level must be an Integer or respond to #to_int")
        to_a.flatten(level)
      end

      # Return a new map of the same class with interchangeable Symbol and String keys.
      # Other key types and nested hashes are not normalized. Existing normalization is replaced.
      # The copy preserves its value mode, value comparison, capacity, and Local scope where supported.
      # Keys use equality. Entries from the current scope seed a Local copy.
      # Values in move mode are copied to preserve the source.
      # @return [Map] An independent map with indifferent key access.
      def with_indifferent_access
        normalizer = Ractor.shareable_proc { |key| Symbol === key ? key.name : key }
        build_indifferent_access(**indifferent_access_options, normalize_keys: normalizer)
      end

      # Compatibility method for ActiveSupport.
      # @return [Boolean] true
      def duplicable? = true

      protected

      # The backing map used by copying and transformation operations.
      # Scoped maps override this to resolve storage for the current scope.
      # @api private
      def internal_map = @map

      private

      def initialize_dup(other)
        super
        publish_shareable_copy(other, operation: :dup) if is_a?(Shareable)
      end

      def initialize_clone(other, freeze: nil)
        super
        publish_shareable_copy(other, operation: :clone, freeze:) if is_a?(Shareable)
      end

      def initialize_copy(other, empty: false)
        super(other)
        normalizer = other.instance_variable_get(:@key_normalizer)
        if normalizer && !is_a?(ConcurrentMap)
          operations = Internal::KeyNormalizer.operations_for(self)
          Internal::KeyNormalizer.install(self, normalizer, operations) unless is_a?(operations)
        end
        install_copied_map(copy_map_backend(other.internal_map, empty:))
      end

      def install_copied_map(map) = @map = map

      def empty_copy
        # Preserve wrapper settings without copying entries or rerunning the public constructor.
        copy = self.class.allocate
        instance_variables.each { |name| copy.instance_variable_set(name, instance_variable_get(name)) }
        copy.__send__(:initialize_copy, self, empty: true)
        copy.__send__(:publish_shareable) if is_a?(Shareable)
        copy
      end

      def with_map_copy(empty: false)
        copy = empty ? empty_copy : dup
        map  = copy.internal_map
        map  = map.instance_variable_get(:@map) if map.is_a?(Internal::KeyNormalizer::ConcurrentMap)
        yield copy, map
        copy
      end

      def normalize_copied_key(key)
        normalizer = instance_variable_get(:@key_normalizer)
        normalizer ? normalizer.call(key) : key
      end

      def indifferent_access_options = respond_to?(:mode) ? { mode: mode } : {}

      def build_indifferent_access(**options)
        entries = self
        if options[:mode] == :move
          copier  = ModeManager.new(mode: :copy)
          entries = each_pair.map { |key, value| [key, copier.unwrap(copier.wrap(value))] }
        end
        self.class.new(entries, **options)
      end
    end
  end
end
