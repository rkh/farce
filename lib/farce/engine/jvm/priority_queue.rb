# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/jvm/types"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    module JVMBasePriorityQueueBackend
      EMPTY = Object.new.freeze
      DEFAULT_CAPACITY = 1024
      INITIALIZATION_LOCK = Mutex.new
      INITIALIZE_INTERRUPT_MASK = { Exception => :never }.freeze
      private_constant :EMPTY, :DEFAULT_CAPACITY, :INITIALIZATION_LOCK, :INITIALIZE_INTERRUPT_MASK

      def try_push(priority, value)
        check_local_frozen
        access do
          check_open
          return false if @capacity && storage_size >= @capacity

          storage_push(priority, value)
          true
        end
      end

      def capacity
        raise "priority queue is not initialized" unless defined?(@state)

        @capacity
      end

      def try_pop(&fallback)
        check_local_frozen
        read(:pop, fallback)
      end

      def peek(&fallback) = read(:peek, fallback)

      def peek_priority(&fallback) = read(:priority, fallback)

      def delete(priority, value)
        check_local_frozen
        access do
          check_open
          storage_delete(priority, value, identity: false)
        end
      end

      def delete_identity(priority, value)
        check_local_frozen
        access do
          check_open
          storage_delete(priority, value, identity: true)
        end
      end

      def size = access { storage_size }

      def empty? = access { storage_size.zero? }

      def clear
        check_local_frozen
        access { storage_clear }
        self
      end

      def close
        check_local_frozen
        access { storage_close }
        self
      end

      def closed? = access { @state.closed }

      def initialize_copy(_other)
        raise TypeError, "priority queues cannot be copied"
      end

      private

      def initialize_storage(capacity: DEFAULT_CAPACITY, signal: nil)
        raise "priority queue is already initialized" if defined?(@state)
        raise FrozenError, "can't modify frozen #{self.class}" if JVMContainers.frozen_object?(self)

        parsed_capacity = normalize_capacity(capacity)
        validate_signal(signal)
        guard = JVMOperationGuard.new(
          synchronized:    synchronized?,
          label:           "priority queue",
          recursive_error: ThreadError,
        )
        state = build_state

        if synchronized?
          guard.synchronize do
            publish_initialization(parsed_capacity, signal, guard, state)
          end
        else
          publish_initialization(parsed_capacity, signal, guard, state)
        end
      end

      def publish_initialization(parsed_capacity, signal, guard, state)
        INITIALIZATION_LOCK.synchronize do
          Thread.handle_interrupt(INITIALIZE_INTERRUPT_MASK) do
            raise "priority queue is already initialized" if defined?(@state)
            raise FrozenError, "can't modify frozen #{self.class}" if
              JVMContainers.frozen_object?(self)

            @capacity = parsed_capacity
            @signal = signal
            @change_signal = signal
            @guard = guard
            @state = state
            JVMContainers.freeze_object(self) if synchronized?
          end
        end
      end

      def read(kind, fallback)
        result = access do
          check_open
          storage_read(kind)
        end
        return result unless EMPTY.equal?(result)

        fallback&.call
      end

      def empty_result = EMPTY

      def access(&)
        raise "priority queue is not initialized" unless defined?(@guard) && @guard

        @guard.synchronize(&)
      end

      def check_open
        raise ClosedQueueError, "queue is closed" if @state.closed
      end

      def normalize_capacity(value)
        return nil if value.nil?

        unless JVMContainers.is_a?(value, Integer)
          raise TypeError, "capacity must be an Integer or nil" unless value.respond_to?(:to_int)

          value = value.to_int
        end
        raise TypeError, "capacity must be an Integer or nil" unless JVMContainers.is_a?(value, Integer)
        raise ArgumentError, "capacity must be positive or nil" unless value.positive?

        value
      end

      def copy_string(value)
        JVMContainers.string?(value) ? JVMContainers.copy_frozen_string(value) : value
      end

      def check_local_frozen
        raise FrozenError, "can't modify frozen #{self.class}" if
          !synchronized? && JVMContainers.frozen_object?(self)
      end

      def validate_signal(signal)
        return if signal.nil?
        raise ArgumentError, "signal is only supported by a synchronized queue" unless synchronized?
        raise TypeError, "signal must respond to #broadcast" unless signal.respond_to?(:broadcast)
      end

      def synchronized? = false

      def build_state = raise NotImplementedError
      def storage_clear = raise NotImplementedError
      def storage_close = @state.closed = true
      def storage_delete(*) = raise NotImplementedError
      def storage_push(*) = raise NotImplementedError
      def storage_read(*) = raise NotImplementedError
      def storage_size = raise NotImplementedError
    end

    # TreeMap bucket backend selected by the JVM shootout. Each distinct
    # priority owns an ArrayDeque FIFO bucket. Identity cancellation lazily
    # builds an object-id index for large buckets and uses tombstones so the
    # indexed path does not pay ArrayDeque's O(n) arbitrary-removal cost. Both
    # JVM variants use this structure: java.util.PriorityQueue was rejected
    # because an exception from a Ruby comparator can corrupt a heap mid-sift.
    module JVMPriorityQueueBackend
      include JVMBasePriorityQueueBackend

      BucketEntry = Struct.new(:value, :cancelled, :identity_token)
      PriorityKey = Struct.new(:priority, :mutation_owner)
      IdentitySlot = Struct.new(:items, :offset)
      Bucket = Struct.new(:deque, :live_size, :dead_size, :identity_index)
      KEY_COMPARATOR = JVMContainers.comparator do |left, right|
        next 0 if left.equal?(right)

        comparison = JVMContainers.compare(left.priority, right.priority)
        owner = left.mutation_owner || right.mutation_owner
        raise FrozenError, "can't modify frozen #{owner.class}" if
          owner && JVMContainers.frozen_object?(owner)
        comparison
      end

      IDENTITY_INDEX_THRESHOLD = 32
      INTERRUPT_MASK = { Exception => :never }.freeze
      State = Struct.new(:tree, :item_count, :closed)
      private_constant :BucketEntry, :PriorityKey, :IdentitySlot, :Bucket,
        :KEY_COMPARATOR, :IDENTITY_INDEX_THRESHOLD, :INTERRUPT_MASK, :State

      private

      def build_state
        map = JVMContainers::TreeMap.new(KEY_COMPARATOR)
        State.new(map, 0, false)
      end

      def storage_push(priority, value)
        candidate = nil
        completed = false
        begin
          lookup_key = mutation_key(priority)
          bucket = JVMContainers.nullable(@state.tree.get(lookup_key))
          unless bucket
            stored_priority = copy_string(priority)
            check_local_frozen
            lookup_key = mutation_key(stored_priority)
            candidate = Bucket.new(JVMContainers::ArrayDeque.new, 0, 0, nil)
            begin
              existing = JVMContainers.nullable(@state.tree.putIfAbsent(lookup_key, candidate))
              bucket = existing || candidate
            ensure
              # A stored key must not retain mutation context: ordinary lookups
              # remain valid after a local container is frozen.
              Thread.handle_interrupt(INTERRUPT_MASK) do
                lookup_key.mutation_owner = nil
              end
            end
          end

          # Prepare every allocating/failable part before notifying. The entry
          # is a tombstone until commit; every unwind removes it again.
          next_bucket_size = bucket.live_size + 1
          next_size = @state.item_count + 1
          entry = BucketEntry.new(value, true, nil)
          Thread.handle_interrupt(INTERRUPT_MASK) do
            prepared = false
            committed = false
            begin
              bucket.deque.offerLast(entry)
              prepared = true
              identity_index_add(bucket.identity_index, entry) if bucket.identity_index
              notify_change
              entry.cancelled = false
              bucket.live_size = next_bucket_size
              @state.item_count = next_size
              committed = true
            ensure
              rollback_prepared_push(bucket, entry) if prepared && !committed
            end
          end
          completed = true
        ensure
          remove_empty_candidate(candidate) if candidate && !completed
        end
      end

      def storage_read(kind)
        map_entry = first_live_map_entry
        return empty_result if map_entry.nil?
        return map_entry.getKey.priority if kind == :priority

        bucket = map_entry.getValue
        prune_cancelled_head(bucket)
        entry = JVMContainers.nullable(bucket.deque.peekFirst)
        raise "priority bucket lost its live head" if entry.nil?
        return entry.value if kind == :peek

        next_bucket_size = bucket.live_size - 1
        next_size = @state.item_count - 1
        removal_iterator = first_map_removal_iterator(bucket) if next_bucket_size.zero?
        commit_change do
          removed = bucket.deque.pollFirst
          raise "priority bucket changed while locked" unless removed.equal?(entry)

          entry.cancelled = true
          identity_index_discard(bucket.identity_index, entry) if bucket.identity_index
          bucket.live_size = next_bucket_size
          @state.item_count = next_size
          removal_iterator&.remove
        end
        entry.value
      end

      def storage_delete(priority, value, identity:) # rubocop:disable Naming/PredicateMethod
        key = mutation_key(priority)
        bucket = JVMContainers.nullable(@state.tree.get(key))
        return false unless bucket

        entry = if identity
                  if !bucket.identity_index && bucket.live_size >= IDENTITY_INDEX_THRESHOLD
                    bucket.identity_index = build_identity_index(bucket)
                  end
                  if bucket.identity_index
                    identity_index_find(bucket.identity_index, value)
                  else
                    find_identical_entry(bucket, value)
                  end
                else
                  find_equal_entry(bucket, value)
                end
        check_local_frozen
        return false unless entry

        next_bucket_size = bucket.live_size - 1
        next_size = @state.item_count - 1
        next_dead_size = bucket.dead_size + 1
        removal_iterator = map_removal_iterator(key, bucket) if next_bucket_size.zero?
        replacement = prepare_compaction(bucket, entry)
        commit_change do
          cancel_entry(
            bucket,
            entry,
            removal_iterator,
            replacement,
            next_bucket_size,
            next_size,
            next_dead_size,
          )
        end
        true
      end

      def storage_size = @state.item_count

      def storage_clear
        commit_change do
          @state.tree.clear
          @state.item_count = 0
        end
      end

      def storage_close
        commit_change { @state.closed = true }
      end

      def each_live_entry(bucket)
        iterator = bucket.deque.iterator
        while iterator.hasNext
          entry = iterator.next
          yield entry unless entry.cancelled
        end
      end

      def find_equal_entry(bucket, value)
        each_live_entry(bucket) { |entry| return entry if entry.value == value }
        nil
      end

      def find_identical_entry(bucket, value)
        each_live_entry(bucket) do |entry|
          return entry if JVMContainers.identical?(entry.value, value)
        end
        nil
      end

      def identity_index_add(index, entry)
        token = entry.identity_token ||= JVMContainers.identity_token(entry.value)
        slot = index[token]
        if slot
          slot.items << entry
        else
          index[token] = IdentitySlot.new([entry], 0)
        end
      end

      def build_identity_index(bucket)
        index = {}
        each_live_entry(bucket) { |entry| identity_index_add(index, entry) }
        index
      end

      def identity_index_find(index, value)
        token = JVMContainers.identity_token(value)
        slot = index[token]
        return unless slot

        identity_slot_advance(index, token, slot)
        return unless index.key?(token)

        entry = slot.items[slot.offset]
        entry if JVMContainers.identical?(entry.value, value)
      end

      def identity_index_discard(index, entry)
        token = entry.identity_token
        slot = index[token]
        identity_slot_advance(index, token, slot) if slot
      end

      def identity_index_rollback_add(index, entry)
        return unless index

        token = entry.identity_token
        slot = index[token]
        return unless slot

        removed = slot.items.pop
        raise "priority identity index lost its prepared tail" unless removed.equal?(entry)

        index.delete(token) if slot.offset >= slot.items.length
      end

      def identity_slot_advance(index, token, slot)
        entries = slot.items
        offset = slot.offset
        offset += 1 while offset < entries.length && entries[offset].cancelled
        if offset >= entries.length
          index.delete(token)
          return
        end

        slot.offset = offset
      end

      def cancel_entry(
        bucket,
        entry,
        removal_iterator,
        replacement,
        next_bucket_size,
        next_size,
        next_dead_size
      )
        entry.cancelled = true
        identity_index_discard(bucket.identity_index, entry) if bucket.identity_index
        bucket.live_size = next_bucket_size
        @state.item_count = next_size

        if next_bucket_size.zero?
          removal_iterator.remove
        elsif replacement
          bucket.deque, bucket.identity_index = replacement
          bucket.dead_size = 0
        else
          bucket.dead_size = next_dead_size
        end
      end

      def rollback_prepared_push(bucket, entry)
        removed = bucket.deque.pollLast
        raise "priority bucket lost its prepared tail" unless removed.equal?(entry)

        identity_index_rollback_add(bucket.identity_index, entry)
      end

      def remove_empty_candidate(candidate)
        return unless candidate.live_size.zero?

        iterator = @state.tree.entrySet.iterator
        while iterator.hasNext
          entry = iterator.next
          next unless entry.getValue.equal?(candidate)

          iterator.remove
          return
        end
      end

      def first_live_map_entry
        loop do
          entry = JVMContainers.nullable(@state.tree.firstEntry)
          return if entry.nil?
          return entry if entry.getValue.live_size.positive?

          @state.tree.pollFirstEntry
        end
      end

      # Keep an iterator positioned on the exact map node while comparisons
      # are still allowed to fail. Iterator#remove then performs the post-
      # notification structural commit without invoking the Ruby comparator.
      def map_removal_iterator(key, bucket)
        iterator = @state.tree.tailMap(key, true).entrySet.iterator
        raise "priority map lost its bucket" unless iterator.hasNext

        entry = iterator.next
        raise "priority map selected the wrong bucket" unless entry.getValue.equal?(bucket)

        iterator
      end

      def first_map_removal_iterator(bucket)
        iterator = @state.tree.entrySet.iterator
        raise "priority map lost its first bucket" unless iterator.hasNext

        entry = iterator.next
        raise "priority map selected the wrong first bucket" unless entry.getValue.equal?(bucket)

        iterator
      end

      def mutation_key(priority)
        owner = self unless synchronized?
        PriorityKey.new(priority, owner)
      end

      def prune_cancelled_head(bucket)
        loop do
          entry = JVMContainers.nullable(bucket.deque.peekFirst)
          break if entry.nil? || !entry.cancelled

          bucket.deque.pollFirst
          bucket.dead_size -= 1
        end
      end

      def prepare_compaction(bucket, cancelled_entry)
        projected_dead = bucket.dead_size + 1
        projected_live = bucket.live_size - 1
        return unless projected_live.positive?
        return unless projected_dead >= IDENTITY_INDEX_THRESHOLD && projected_dead >= projected_live

        replacement = JVMContainers::ArrayDeque.new(projected_live)
        iterator = bucket.deque.iterator
        while iterator.hasNext
          entry = iterator.next
          replacement.offerLast(entry) unless entry.cancelled || entry.equal?(cancelled_entry)
        end

        replacement_index = if bucket.identity_index
                              index = {}
                              iterator = replacement.iterator
                              identity_index_add(index, iterator.next) while iterator.hasNext
                              index
                            end
        [replacement, replacement_index]
      end

      def notify_change
        @change_signal&.broadcast
      end

      # Notification is deliberately pre-commit so a synchronous Signal error
      # leaves the queue unchanged. Once notification starts, however, an
      # asynchronously injected exception cannot safely distinguish which
      # waiters observed it. Defer only those asynchronous exceptions until the
      # small, allocation-free state commit has completed.
      def commit_change
        Thread.handle_interrupt(INTERRUPT_MASK) do
          notify_change
          yield
        end
      end
    end

    # Coarse-lock ordered storage used directly by the blocking methods which
    # are added below from the engine-neutral implementation.
    class PriorityQueue
      include JVMPriorityQueueBackend

      private

      def synchronized? = true
    end

    private_constant :JVMBasePriorityQueueBackend, :JVMPriorityQueueBackend
  end
end

require "farce/engine/shared/priority_queue"
