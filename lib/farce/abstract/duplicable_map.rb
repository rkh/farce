# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # Map operations that return independent maps of the same kind.
    # Include this in subclasses of {Map} that support copying.
    module DuplicableMap
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

      private

      def indifferent_access_options
        respond_to?(:mode) ? { mode: mode } : {}
      end

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
