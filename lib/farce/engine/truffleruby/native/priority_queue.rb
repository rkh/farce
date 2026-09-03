# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/truffleruby/native/ordered_array_support"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Synchronized minimum-priority queue for native TruffleRuby. Binary
    # search locates a priority bucket, whose small Array preserves FIFO order.
    class PriorityQueue
      include TruffleOrderedArraySupport

      DEFAULT_CAPACITY = nil
      EMPTY = Object.new.freeze
      INITIALIZATION_LOCK = Mutex.new
      private_constant :DEFAULT_CAPACITY, :EMPTY, :INITIALIZATION_LOCK

      Bucket = Struct.new(:priority, :items)
      private_constant :Bucket

      class State
        attr_accessor :size, :closed, :operation_owner
        attr_reader :buckets, :capacity, :signal, :lock

        def initialize(capacity:, signal:, lock:)
          @buckets = []
          @capacity = capacity
          @signal = signal
          @lock = lock
          @size = 0
          @closed = false
          @operation_owner = nil
        end
      end
      private_constant :State

      def initialize(capacity: DEFAULT_CAPACITY, signal: nil)
        ensure_initializable!
        capacity = normalize_capacity(capacity)
        signal = normalize_signal(signal)
        prepared = State.new(capacity:, signal:, lock: Lock.new)
        commit_initialization(prepared)
      end
      private :initialize

      def initialize_copy(_other)
        raise TypeError, "priority queues cannot be copied"
      end

      def push(priority, value)
        state = initialized_state
        with_queue_operation(state) do
          raise_closed if state.closed
          next false if state.capacity && state.size >= state.capacity

          index, found = locate_priority(state.buckets, priority)
          if found
            bucket = state.buckets[index]
            prepared_items = bucket.items.dup << value
            notify_and_commit(state) do
              bucket.items = prepared_items
              state.size += 1
            end
          else
            pending = Bucket.new(snapshot_ordered_key(priority), [value])
            notify_and_commit(state) do
              index, duplicate = with_interruptible_callbacks do
                locate_priority(state.buckets, priority)
              end
              raise "priority comparator changed during insertion" if duplicate
              state.buckets.insert(index, pending)
              state.size += 1
            end
          end
          true
        end
      end

      def pop(&fallback)
        pop_endpoint(last: false, fallback:)
      end

      def pop_last(&fallback)
        pop_endpoint(last: true, fallback:)
      end

      def peek(&fallback)
        read_endpoint(:value, last: false, fallback:)
      end

      def peek_last(&fallback)
        read_endpoint(:value, last: true, fallback:)
      end

      def peek_priority(&fallback)
        read_endpoint(:priority, last: false, fallback:)
      end

      def peek_last_priority(&fallback)
        read_endpoint(:priority, last: true, fallback:)
      end

      def delete(priority, value)
        delete_value(priority, value, identity: false)
      end

      def delete_identity(priority, value)
        delete_value(priority, value, identity: true)
      end

      def size
        state = initialized_state
        with_queue_operation(state) { state.size }
      end

      def empty?
        state = initialized_state
        with_queue_operation(state) { state.size.zero? } # rubocop:disable Style/ZeroLengthPredicate
      end

      def capacity = initialized_state.capacity

      def clear
        state = initialized_state
        with_queue_operation(state) do
          notify_and_commit(state) do
            state.buckets.clear
            state.size = 0
          end
          self
        end
      end

      def close
        state = initialized_state
        with_queue_operation(state) do
          notify_and_commit(state) { state.closed = true }
          self
        end
      end

      def closed?
        state = initialized_state
        with_queue_operation(state) { state.closed }
      end

      private

      def pop_endpoint(last:, fallback:)
        state = initialized_state
        result = with_queue_operation(state) do
          raise_closed if state.closed
          bucket = last ? state.buckets.last : state.buckets.first
          next EMPTY unless bucket

          value = bucket.items.first
          prepared_items = bucket.items.drop(1)
          notify_and_commit(state) do
            if prepared_items.empty?
              last ? state.buckets.pop : state.buckets.shift
            else
              bucket.items = prepared_items
            end
            state.size -= 1
          end
          value
        end
        return result unless EMPTY.equal?(result)
        fallback&.call
      end

      def ensure_initializable!
        raise "priority queue is already initialized" if @state
        raise FrozenError, "can't modify frozen priority queue" if primitive_frozen?(self)
      end

      def commit_initialization(prepared)
        INITIALIZATION_LOCK.synchronize do
          raise "priority queue is already initialized" if @state
          raise FrozenError, "can't modify frozen priority queue" if primitive_frozen?(self)

          without_async_interrupts do
            @state = prepared
            primitive_freeze(self)
          end
        end
        self
      end

      def initialized_state
        @state || raise("uninitialized priority queue")
      end

      def normalize_capacity(capacity)
        return nil if capacity.nil?
        capacity = capacity.to_int unless primitive_is_a?(capacity, Integer)
        raise TypeError, "capacity must be an Integer or nil" unless primitive_is_a?(capacity, Integer)
        raise ArgumentError, "capacity must be positive or nil" unless capacity.positive?
        capacity
      end

      def normalize_signal(signal)
        return if signal.nil?
        raise TypeError, "signal must respond to #broadcast" unless signal.respond_to?(:broadcast)
        signal
      end

      def with_queue_operation(state)
        current = Fiber.current
        raise ThreadError, "deadlock; recursive priority queue access" if
          primitive_identical?(state.operation_owner, current)

        state.lock.synchronize do
          without_async_interrupts { state.operation_owner = current }
          yield
        ensure
          without_async_interrupts do
            state.operation_owner = nil if primitive_identical?(state.operation_owner, current)
          end
        end
      end

      def read_endpoint(kind, last:, fallback:)
        state = initialized_state
        result = with_queue_operation(state) do
          raise_closed if state.closed
          bucket = last ? state.buckets.last : state.buckets.first
          next EMPTY unless bucket
          kind == :priority ? bucket.priority : bucket.items.first
        end
        EMPTY.equal?(result) ? fallback&.call : result
      end

      def delete_value(priority, value, identity:)
        state = initialized_state
        with_queue_operation(state) do
          raise_closed if state.closed
          bucket_index, found = locate_priority(state.buckets, priority)
          next false unless found

          bucket = state.buckets[bucket_index]
          item_index = if identity
                         bucket.items.index { primitive_identical?(it, value) }
                       else
                         bucket.items.index { it == value }
                       end
          next false unless item_index

          prepared_items = bucket.items.dup
          prepared_items.delete_at(item_index)
          notify_and_commit(state) do
            if prepared_items.empty?
              state.buckets.delete_at(bucket_index)
            else
              bucket.items = prepared_items
            end
            state.size -= 1
          end
          true
        end
      end

      def locate_priority(buckets, priority)
        low = 0
        high = buckets.length
        while low < high
          middle = (low + high) / 2
          order = compare_priorities(priority, buckets[middle].priority)
          return [middle, true] if order.zero?
          order.negative? ? high = middle : low = middle + 1
        end
        [low, false]
      end

      def compare_priorities(left, right)
        result = left <=> right
        raise ArgumentError, "priority comparison failed" if result.nil?
        # rb_cmpint calls #> and #< when <=> returns a non-Integer object.
        return 1 if result > 0 # rubocop:disable Style/NumericPredicate
        return -1 if result < 0 # rubocop:disable Style/NumericPredicate
        0
      end

      def notify_and_commit(state)
        without_async_interrupts do
          with_interruptible_callbacks { state.signal.broadcast } if state.signal
          yield
        end
      end

      def raise_closed
        raise ClosedQueueError, "queue is closed"
      end
    end
  end
end
