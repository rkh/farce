# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/truffleruby/native/ordered_array_support"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Unsynchronized ordered map for callers that provide their own ownership.
    # Entries live in one sorted Array and are located by binary search.
    class UnsafeTreeMap
      include TruffleOrderedArraySupport

      INITIALIZATION_LOCK = Mutex.new
      private_constant :INITIALIZATION_LOCK

      Entry = Struct.new(:key, :value)
      private_constant :Entry

      class State
        attr_accessor :operation_owner
        attr_reader :entries, :lock

        def initialize(lock:)
          @entries = []
          @lock = lock
          @operation_owner = nil
        end
      end
      private_constant :State

      def initialize(entries = nil)
        ensure_initializable!
        entries = normalize_entries(entries)
        prepared = State.new(lock: operation_lock)
        entries&.each { |key, value| stage_store(prepared, key, value) }
        commit_initialization(prepared)
      end

      def initialize_copy(_other)
        raise TypeError, "tree maps cannot be copied"
      end

      def prepare_key(key) = canonical_ordered_key(key)

      def [](key)
        key = canonical_ordered_key(key)
        state = initialized_state
        with_map_operation(state, mutation: false) do
          index, found = locate_key(state.entries, key)
          state.entries[index].value if found
        end
      end

      def fetch(*arguments)
        unless arguments.length.between?(1, 2)
          raise ArgumentError, "wrong number of arguments (given #{arguments.length}, expected 1..2)"
        end

        original_key, default = arguments
        key = canonical_ordered_key(original_key)
        default_given = arguments.length == 2
        warn "block supersedes default value argument", uplevel: 1 if block_given? && default_given
        state = initialized_state
        entry = with_map_operation(state, mutation: false) do
          index, found = locate_key(state.entries, key)
          state.entries[index] if found
        end
        return entry.value if entry
        return yield(original_key) if block_given?
        return default if default_given

        raise KeyError.new(
          "key not found: #{original_key.inspect}",
          receiver: self,
          key:      original_key,
        )
      end

      def key?(key)
        key = canonical_ordered_key(key)
        state = initialized_state
        with_map_operation(state, mutation: false) do
          _, found = locate_key(state.entries, key)
          found
        end
      end

      def getkey(key)
        key = canonical_ordered_key(key)
        state = initialized_state
        with_map_operation(state, mutation: false) do
          index, found = locate_key(state.entries, key)
          state.entries[index].key if found
        end
      end

      def each
        return enum_for(__method__) { size } unless block_given?

        state = initialized_state
        entries = with_map_operation(state, mutation: false) do
          state.entries.map { [it.key, it.value] }
        end
        entries.each { yield it }
        self
      end

      def []=(key, value)
        key = canonical_ordered_key(key)
        state = initialized_state
        with_map_operation(state, mutation: true) do
          index, found = locate_key(state.entries, key)
          if found
            ensure_mutation_still_allowed!
            without_async_interrupts { state.entries[index].value = value }
          else
            pending = Entry.new(key, value)
            without_async_interrupts do
              index, duplicate = with_interruptible_callbacks do
                locate_key(state.entries, key)
              end
              raise "key comparator changed during insertion" if duplicate
              ensure_mutation_still_allowed!
              state.entries.insert(index, pending)
            end
          end
          value
        end
      end

      def delete(key)
        key = canonical_ordered_key(key)
        state = initialized_state
        with_map_operation(state, mutation: true) do
          index, found = locate_key(state.entries, key)
          next unless found

          ensure_mutation_still_allowed!
          without_async_interrupts { state.entries.delete_at(index).value }
        end
      end

      def first_key
        state = initialized_state
        with_map_operation(state, mutation: false) { state.entries.first&.key }
      end

      def last_key
        state = initialized_state
        with_map_operation(state, mutation: false) { state.entries.last&.key }
      end

      def shift
        state = initialized_state
        with_map_operation(state, mutation: true) do
          entry = state.entries.first
          next unless entry

          pair = [entry.key, entry.value]
          without_async_interrupts { state.entries.shift }
          pair
        end
      end

      def pop
        state = initialized_state
        with_map_operation(state, mutation: true) do
          entry = state.entries.last
          next unless entry

          pair = [entry.key, entry.value]
          without_async_interrupts { state.entries.pop }
          pair
        end
      end

      def size
        state = initialized_state
        with_map_operation(state, mutation: false) { state.entries.length }
      end
      alias length size

      def empty?
        state = initialized_state
        with_map_operation(state, mutation: false) { state.entries.empty? }
      end

      def clear
        state = initialized_state
        with_map_operation(state, mutation: true) do
          without_async_interrupts { state.entries.clear }
          self
        end
      end

      private

      def synchronized? = false
      def operation_lock = nil

      def with_map_operation(state, mutation:)
        ensure_mutation_still_allowed! if mutation
        current = Fiber.current
        raise "container cannot be modified during comparison" if state.operation_owner

        begin
          without_async_interrupts { state.operation_owner = current }
          yield
        ensure
          without_async_interrupts { state.operation_owner = nil }
        end
      end

      def ensure_mutation_still_allowed!
        raise FrozenError, "can't modify frozen tree map" if primitive_frozen?(self)
      end

      def ensure_initializable!
        raise "tree map is already initialized" if @state
        raise FrozenError, "can't modify frozen tree map" if primitive_frozen?(self)
      end

      def commit_initialization(prepared)
        INITIALIZATION_LOCK.synchronize do
          raise "tree map is already initialized" if @state
          raise FrozenError, "can't modify frozen tree map" if primitive_frozen?(self)

          without_async_interrupts do
            @state = prepared
            primitive_freeze(self) if synchronized?
          end
        end
        self
      end

      def initialized_state
        @state || raise("uninitialized tree map")
      end

      def normalize_entries(entries)
        return if entries.nil?
        entries = Hash.try_convert(entries)
        return entries if entries
        raise TypeError, "entries must be a Hash or respond to #to_hash"
      end

      def stage_store(state, key, value)
        key = canonical_ordered_key(key)
        index, found = locate_key(state.entries, key)
        if found
          ensure_initializable!
          state.entries[index].value = value
          return
        end

        pending = Entry.new(key, value)
        index, duplicate = locate_key(state.entries, key)
        raise "key comparator changed during insertion" if duplicate
        ensure_initializable!
        state.entries.insert(index, pending)
      end

      def locate_key(entries, key)
        low = 0
        high = entries.length
        while low < high
          middle = (low + high) / 2
          order = compare_keys(key, entries[middle].key)
          return [middle, true] if order.zero?
          order.negative? ? high = middle : low = middle + 1
        end
        [low, false]
      end

      def compare_keys(left, right)
        result = left <=> right
        raise ArgumentError, "key comparison failed" if result.nil?
        # rb_cmpint calls #> and #< when <=> returns a non-Integer object.
        return 1 if result > 0 # rubocop:disable Style/NumericPredicate
        return -1 if result < 0 # rubocop:disable Style/NumericPredicate
        0
      end
    end
  end
end
