# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    module StrictTreeMapValues
      def initialize(entries = nil)
        unless entries.nil? || entries.is_a?(Hash)
          entries = entries.to_hash if entries.respond_to?(:to_hash)
          raise TypeError, "entries must be a Hash or respond to #to_hash" unless entries.is_a?(Hash)
        end
        entries&.each { |key, value| check_tree_pair(key, value) }
        super
      end

      def [](key) = super(check_tree_key(key))

      def []=(key, value)
        super(check_tree_key(key), check_tree_value(value))
      end

      def delete(key) = super(check_tree_key(key))
      def getkey(key) = super(check_tree_key(key))
      def key?(key)   = super(check_tree_key(key))

      def fetch(*arguments, &)
        check_tree_key(arguments.first) unless arguments.empty?
        super
      end

      private

      def check_tree_pair(key, value)
        check_tree_key(key)
        check_tree_value(value)
      end

      def check_tree_key(key)
        return key if String === key || Ractor.shareable?(key)
        raise Ractor::IsolationError, "key must be Ractor-shareable"
      end

      def check_tree_value(value)
        return value if Ractor.shareable?(value)
        raise Ractor::IsolationError, "value must be Ractor-shareable"
      end
    end
    private_constant :StrictTreeMapValues

    class StrictTreeMap < ShareableTreeMap
      include StrictTreeMapValues
    end
  end
end
