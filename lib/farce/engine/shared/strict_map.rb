# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    module StrictMapValues
      def initialize(initial_mapping = nil, **)
        raise TypeError, "initial mapping must be a Hash" unless initial_mapping.nil? || initial_mapping.is_a?(Hash)
        initial_mapping&.each { |key, value| check_pair(key, value) }
        super
      end

      def [](key) = super(check_key(key))

      def []=(key, value)
        super(check_key(key), check_value(value))
      end

      def get(key, **)                = super(check_key(key), **)
      def store(key, value, **)       = super(check_key(key), check_value(value), **)
      def swap(key, value, **)        = super(check_key(key), check_value(value), **)
      def key?(key)                   = super(check_key(key))
      def delete(key)                 = super(check_key(key))
      def getkey(key)                 = super(check_key(key))
      def wait_until_non_nil(key, **) = super(check_key(key), **)

      def fetch(*arguments, &)
        check_key(arguments.first) unless arguments.empty?
        super
      end

      def store_if_absent(key, **)
        raise LocalJumpError, "no block given" unless block_given?
        super(check_key(key), **) { check_value(yield) }
      end

      def compare_and_set(key, expected, replacement, **)
        super(check_key(key), check_value(expected), check_value(replacement), **)
      end

      def update(key, **)
        raise LocalJumpError, "no block given" unless block_given?
        super(check_key(key), **) { |value| check_value(yield(value)) }
      end

      def upsert(key, initial, **)
        raise LocalJumpError, "no block given" unless block_given?
        super(check_key(key), check_value(initial), **) { |value| check_value(yield(value)) }
      end

      def wait_until_changed(key, expected, **)
        super(check_key(key), check_value(expected), **)
      end

      private

      def check_pair(key, value)
        check_key(key)
        check_value(value)
      end

      def check_key(key)
        return key if Ractor.shareable?(key)
        raise Ractor::IsolationError, "key must be Ractor-shareable"
      end

      def check_value(value)
        return value if Ractor.shareable?(value)
        raise Ractor::IsolationError, "value must be Ractor-shareable"
      end
    end
    private_constant :StrictMapValues

    class StrictMap < Map
      include StrictMapValues
    end

    class StrictWeakKeyMap < WeakKeyMap
      include StrictMapValues
    end

    class StrictWeakValueMap < WeakValueMap
      include StrictMapValues
    end

    class StrictWeakMap < WeakMap
      include StrictMapValues
    end
  end
end
