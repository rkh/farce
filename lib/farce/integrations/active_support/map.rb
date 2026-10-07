# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# @!group ActiveSupport Integration
require "farce/integrations/active_support"

module Farce
  module Abstract
    class Map
      # @!macro active_support
      # Convert entries using ActiveSupport's Hash JSON conversion.
      # @return [Hash] The entries converted using Hash#as_json.
      def as_json(...) = to_h.as_json(...)

      # @!macro active_support
      # Encode public entries as a query string, optionally under a namespace.
      # @return [String]
      def to_query(...) = to_h.to_query(...)
      alias to_param to_query

      # @!macro active_support
      # Validate observed keys without normalizing the allowed keys.
      # Concurrent changes may invalidate the result immediately.
      # @return [self]
      # @raise [ArgumentError] if an observed key is not allowed
      def assert_valid_keys(*valid_keys)
        valid_keys.flatten!
        each_key do |key|
          unless valid_keys.include?(key)
            raise ArgumentError, "Unknown key: #{key.inspect}. Valid keys are: #{valid_keys.map(&:inspect).join(", ")}"
          end
        end
        self
      end
    end

    module DuplicableMap
      # @!macro active_support
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

      # @!macro active_support
      # Deeply copy entries into a map of the same kind with the same settings.
      # String and Symbol keys retain their identity, as with ActiveSupport's Hash#deep_dup.
      # Copied keys and values must satisfy the map's normal storage rules.
      # @return [Map]
      def deep_dup
        copier = ModeManager.new(mode: :copy) if respond_to?(:mode) && mode == :move
        with_map_copy(empty: true) do |copy, map|
          internal_map.each do |key, value|
            key = key.deep_dup unless String === key || Symbol === key
            value = unwrap_value(value).deep_dup
            value = copier.unwrap(copier.wrap(value)) if copier
            map[key] = copy.wrap_value(value)
          end
        end
      end

      # @!macro active_support
      # Return a same-kind map with string keys, subject to its key normalizer.
      # @return [Map]
      def stringify_keys = transform_keys { |key| Symbol === key ? key.name : key.to_s }

      # @!macro active_support
      # Return a same-kind map with symbol keys where conversion succeeds.
      # @return [Map]
      def symbolize_keys
        transform_keys do |key|
          key.to_sym
        rescue StandardError
          key
        end
      end
      alias to_options symbolize_keys

      # @!macro active_support
      # Return a same-kind map without blank values, including false.
      # @return [Map]
      def compact_blank = reject { |_, value| value.blank? }

      # @!macro active_support
      # Return a same-kind map with defaults applied before the receiver's entries.
      # Existing entries win. Bounded copies rebuild eviction history and enforce their capacity.
      # Move-mode defaults are copied so the input remains usable.
      # @param other [Map, Hash, #to_hash] default entries
      # @return [Map]
      def reverse_merge(other)
        unless Map === other
          other = Hash.try_convert(other) || raise(TypeError, "input must be a Map, Hash, or respond to #to_hash")
        end
        copier = ModeManager.new(mode: :copy) if respond_to?(:mode) && mode == :move
        with_map_copy(empty: true) do |copy, map|
          other.each_pair do |key, value|
            key = normalize_copied_key(key)
            value = copier.unwrap(copier.wrap(value)) if copier
            map[key] = copy.wrap_value(value)
          end
          internal_map.each { |key, value| map[key] = value }
        end
      end
      alias with_defaults reverse_merge

      private

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

    class ConcurrentMap
      # @!macro active_support
      # Remove blank values using per-key coordination. Always return self.
      # The operation is not atomic across keys.
      # @return [self]
      def compact_blank! = delete_if { |_, value| value.blank? }

      # @!macro active_support
      # Store each default only if its key is absent, preserving existing nil and false values.
      # Each decision is atomic for its key. Earlier changes survive exceptions.
      # Inserted values use the map's transfer mode, including move semantics.
      # @param other [Map, Hash, #to_hash] default entries
      # @return [self]
      def reverse_merge!(other)
        unless Map === other
          other = Hash.try_convert(other) || raise(TypeError, "input must be a Map, Hash, or respond to #to_hash")
        end
        other.each_pair { |key, value| store_if_absent(key) { value } }
        self
      end
      alias with_defaults! reverse_merge!

      private

      def indifferent_access_options
        super.merge(compare_keys_by_identity: false, compare_values_by_identity: compare_values_by_identity?)
      end
    end

    class BoundedMap
      private

      def indifferent_access_options
        super.merge(max_size:, compare_keys_by_identity: false, compare_values_by_identity: compare_values_by_identity?)
      end
    end
  end

  module Local
    module Scoped
      module Map
        private def indifferent_access_options = super.merge(scope:)
      end
    end
  end

  Internal::Converter.define(ActiveSupport::HashWithIndifferentAccess, :Map) do
    def prepare(...) = super.with_indifferent_access
  end
end
