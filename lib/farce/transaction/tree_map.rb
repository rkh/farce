# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  class Transaction
    # A {Abstract::TreeMap TreeMap} that is part of a transaction.
    class TreeMap < Abstract::TreeMap
      include MapOperations

      # (see Abstract::TreeMap#first_key)
      # @see Abstract::TreeMap#first_key
      def first_key = access { @working.first_key }

      # (see Abstract::TreeMap#last_key)
      # @see Abstract::TreeMap#last_key
      def last_key = access { @working.last_key }

      # (see Abstract::TreeMap#getkey)
      # @see Abstract::TreeMap#getkey
      def getkey(key) = access { @working.getkey(prepare(key)) }

      # (see Abstract::TreeMap#keys)
      # @see Abstract::TreeMap#keys
      def keys = access { @working.each.map { |key, _| key }.freeze }

      # (see Abstract::TreeMap#pop)
      # @see Abstract::TreeMap#pop
      def pop = write { public_pair(@working.pop) }

      # (see Abstract::TreeMap#shift)
      # @see Abstract::TreeMap#shift
      def shift = write { public_pair(@working.shift) }

      # (see Abstract::TreeMap#swap)
      # @see Abstract::TreeMap#swap
      def swap(key, value, mode: nil)
        write do
          canonical = prepare(key)
          previous = unwrap_stored(@working[canonical])
          store_value(canonical, wrap(value, mode:))
          previous
        end
      end

      # (see Abstract::TreeMap#compare_and_set)
      # @see Abstract::TreeMap#compare_and_set
      def compare_and_set(key, expected, replacement, mode: nil)
        write do
          canonical = prepare(key)
          next compared(false) unless @working.key?(canonical)
          current = @working[canonical]
          matches = @manager ? matches?(current, expected, identity: false) : current == expected
          next compared(false) unless matches
          store_value(canonical, wrap(replacement, mode:))
          true
        end
      end

      private

      def store_value(key, value)
        @working[key] = value
      end

      def prepare(key)
        normalizer = @object.instance_variable_get(:@key_normalizer)
        @working.prepare_key(normalizer ? normalizer.call(key) : key)
      end

      def public_pair(pair)
        [pair.first, unwrap_stored(pair.last)] if pair
      end

      Wrapper.inherit(self, *MapOperations::READ_HELPERS)
    end
  end
end
