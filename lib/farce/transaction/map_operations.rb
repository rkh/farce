# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  class Transaction
    # Implements the staged reads and writes shared by Map and TreeMap wrappers.
    #
    # The participant supplies key normalization and value transfer rules.
    # Operations use the backend snapshot enrolled in the transaction, so they
    # see earlier staged writes without modifying the participant before commit.
    #
    # @!visibility private
    module MapOperations # :nodoc: all
      include Wrapper

      READ_HELPERS = %i[
        assoc compare_by_identity? dig length value? has_value? key rassoc has_key? member? include?
        fetch_values to_a to_h to_hash deconstruct_keys values_at weak_keys? weak_values? inspect to_s
        pretty_print values flatten to_proc
      ].freeze

      def [](key) = access { unwrap_stored(@working[prepare(key)]) }

      def []=(key, value)
        store(key, value)
      end

      def fetch(key, *defaults)
        access do
          raise ArgumentError, "expected at most one default" if defaults.size > 1
          canonical = prepare(key)
          next unwrap_stored(@working[canonical]) if @working.key?(canonical)
          next yield(key) if block_given?
          next defaults.first unless defaults.empty?
          raise KeyError.new("key not found: #{key.inspect}", receiver: @object, key:)
        end
      end

      def compare_keys_by_identity?    = access { @object.compare_keys_by_identity? }
      def compare_values_by_identity?  = access { @object.compare_values_by_identity? }
      def delete(key)                  = write { unwrap_stored(@working.delete(prepare(key))) }
      def empty?                       = size.zero?
      def get(key)                     = self[key]
      def getkey(key)                  = access { @working.getkey(prepare(key)) }
      def key?(key)                    = access { @working.key?(prepare(key)) }
      def keys                         = access { @working.keys }
      def shareable_keys?              = access { @object.shareable_keys? }
      def shareable_values?            = access { @object.shareable_values? }
      def size                         = access { @working.size }
      def store(key, value, mode: nil) = write { unwrap_stored(store_value(prepare(key), wrap(value, mode:))) }
      def swap(key, value, mode: nil)  = write { unwrap_stored(@working.swap(prepare(key), wrap(value, mode:))) }

      def each
        return enum_for(__method__) unless block_given?
        access { @working.each { |key, value| yield key, unwrap_stored(value) } }
        self
      end
      alias each_pair each
      alias each_live each

      def clear
        write { @working.clear }
        self
      end

      def update(key, mode: nil)
        require_block!(block_given?)
        write do
          canonical = prepare(key)
          unwrap_stored(store_value(canonical, wrap(yield(unwrap_stored(@working[canonical])), mode:)))
        end
      end

      def store_if_absent(key, mode: nil)
        require_block!(block_given?)
        write do
          canonical = prepare(key)
          next unwrap_stored(@working[canonical]) if @working.key?(canonical)
          unwrap_stored(store_value(canonical, wrap(yield, mode:)))
        end
      end

      def upsert(key, initial, mode: nil)
        require_block!(block_given?)
        write do
          canonical = prepare(key)
          value = @working.key?(canonical) ? yield(unwrap_stored(@working[canonical])) : initial
          unwrap_stored(store_value(canonical, wrap(value, mode:)))
        end
      end

      def compare_and_set(key, expected, replacement, mode: nil)
        write do
          canonical = prepare(key)
          next compared(@working.compare_and_set(canonical, expected, replacement)) unless @manager
          next compared(false) unless @working.key?(canonical) &&
            matches?(@working[canonical], expected, identity: @object.compare_values_by_identity?)
          store_value(canonical, wrap(replacement, mode:))
          true
        end
      end

      def each_key
        return enum_for(__method__) { size } unless block_given?
        each { |key, _| yield key }
        self
      end

      def each_value
        return enum_for(__method__) { size } unless block_given?
        each { |_, value| yield value }
        self
      end

      private

      def store_value(key, value) = @working.store(key, value)

      def modify_entry(key, canonical: false)
        write do
          key = prepare(key) unless canonical
          present = @working.key?(key)
          replacement = yield(present, present ? unwrap_stored(@working[key]) : nil)
          next false if Internal::MAP_KEEP.equal?(replacement)
          if Internal::MAP_DELETE.equal?(replacement)
            @working.delete(key)
            present
          else
            store_value(key, wrap(replacement))
          end
        end
      end

      def prepare(key)
        return @backend.transaction_key(key) if @backend.respond_to?(:transaction_key)
        @backend.respond_to?(:normalize_external_key) ? @backend.normalize_external_key(key) : key
      end
    end

    private_constant :MapOperations
  end
end
