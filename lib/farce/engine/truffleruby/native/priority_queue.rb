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
      TrackedItem = Struct.new(:value, :enqueued_at)
      private_constant :Bucket, :TrackedItem

      class State
        attr_accessor :size, :sealed, :closed, :generation, :operation_owner
        attr_reader :buckets, :capacity, :signal, :lock, :tracked_items, :track_age

        def initialize(capacity:, signal:, lock:, track_age:)
          @buckets = []
          @capacity = capacity
          @signal = signal
          @lock = lock
          @size = 0
          @sealed = false
          @closed = false
          @track_age = track_age
          @tracked_items = [] if track_age
          @generation = 0
          @operation_owner = nil
        end
      end
      private_constant :State

      def initialize(capacity: DEFAULT_CAPACITY, signal: nil, track_age: false)
        ensure_initializable!
        capacity = normalize_capacity(capacity)
        signal = normalize_signal(signal)
        prepared = State.new(capacity:, signal:, lock: Lock.new, track_age: track_age ? true : false)
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
          raise_sealed if state.sealed
          next false if state.capacity && state.size >= state.capacity

          stored = state.track_age ? TrackedItem.new(value, Clock.now) : value

          index, found = locate_priority(state.buckets, priority)
          if found
            bucket = state.buckets[index]
            prepared_items = bucket.items.dup << stored
            notify_and_commit(state) do
              bucket.items = prepared_items
              state.size += 1
              track_push(state, stored)
            end
          else
            pending = Bucket.new(snapshot_ordered_key(priority), [stored])
            notify_and_commit(state) do
              index, duplicate = with_interruptible_callbacks do
                locate_priority(state.buckets, priority)
              end
              raise "priority comparator changed during insertion" if duplicate
              state.buckets.insert(index, pending)
              state.size += 1
              track_push(state, stored)
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

      def pop_before(latest_priority, &fallback)
        pop_endpoint(last: false, fallback:, latest_priority:)
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

      def delete_match(priority, pattern)
        delete_value(priority, pattern, identity: false, match: true)
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
            state.generation += 1 if state.track_age && state.size.positive?
            state.size = 0
            state.tracked_items&.clear
            state.closed = true if state.sealed
          end
          self
        end
      end

      def close
        state = initialized_state
        with_queue_operation(state) do
          notify_and_commit(state) do
            state.generation += 1 if state.track_age && !state.closed
            state.sealed = true
            state.closed = true
          end
          self
        end
      end

      def closed?
        state = initialized_state
        with_queue_operation(state) { state.closed }
      end

      def sealed?
        state = initialized_state
        with_queue_operation(state) { state.sealed }
      end

      def age_tracking? = initialized_state.track_age

      def generation
        state = initialized_state
        with_queue_operation(state) { state.track_age ? state.generation : nil }
      end

      def oldest_enqueued_at
        state = initialized_state
        with_queue_operation(state) { state.tracked_items&.first&.enqueued_at }
      end

      def oldest_age
        timestamp = oldest_enqueued_at
        Clock.now - timestamp if timestamp
      end

      def seal
        state = initialized_state
        with_queue_operation(state) do
          notify_and_commit(state) do
            unless state.sealed
              state.sealed = true
              state.generation += 1 if state.track_age
            end
            state.closed = true if state.size.zero? # rubocop:disable Style/ZeroLengthPredicate
          end
          self
        end
      end

      private

      def pop_endpoint(last:, fallback:, latest_priority: UNDEFINED)
        state = initialized_state
        result = with_queue_operation(state) do
          raise_closed if state.closed
          bucket = last ? state.buckets.last : state.buckets.first
          next EMPTY unless bucket
          if !UNDEFINED.equal?(latest_priority) && compare_priorities(bucket.priority, latest_priority).positive?
            next EMPTY
          end

          stored = bucket.items.first
          prepared_items = bucket.items.drop(1)
          notify_and_commit(state) do
            if prepared_items.empty?
              last ? state.buckets.pop : state.buckets.shift
            else
              bucket.items = prepared_items
            end
            state.size -= 1
            track_remove(state, stored)
            state.closed = true if state.sealed && state.size.zero? # rubocop:disable Style/ZeroLengthPredicate
          end
          tracked_value(state, stored)
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
          kind == :priority ? bucket.priority : tracked_value(state, bucket.items.first)
        end
        EMPTY.equal?(result) ? fallback&.call : result
      end

      def delete_value(priority, value, identity:, match: false)
        state = initialized_state
        with_queue_operation(state) do
          raise_closed if state.closed
          bucket_index, found = locate_priority(state.buckets, priority)
          next false unless found

          bucket = state.buckets[bucket_index]
          item_index = if identity
                         bucket.items.index { primitive_identical?(tracked_value(state, it), value) }
                       elsif match
                         bucket.items.index { value === tracked_value(state, it) } # rubocop:disable Style/CaseEquality
                       else
                         bucket.items.index { tracked_value(state, it) == value }
                       end
          next false unless item_index

          removed = bucket.items[item_index]
          prepared_items = bucket.items.dup
          prepared_items.delete_at(item_index)
          notify_and_commit(state) do
            if prepared_items.empty?
              state.buckets.delete_at(bucket_index)
            else
              bucket.items = prepared_items
            end
            state.size -= 1
            track_remove(state, removed)
            state.closed = true if state.sealed && state.size.zero? # rubocop:disable Style/ZeroLengthPredicate
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

      def tracked_value(state, item) = state.track_age ? item.value : item

      def track_push(state, item)
        return unless state.track_age
        state.tracked_items << item
        state.generation += 1
      end

      def track_remove(state, item)
        return unless state.track_age
        state.tracked_items.delete(item)
        state.generation += 1
      end

      def raise_closed
        raise ::Farce::Queue::ClosedError, "queue is closed"
      end

      def raise_sealed
        raise ::Farce::Queue::SealedError, "queue is sealed"
      end
    end
  end
end
