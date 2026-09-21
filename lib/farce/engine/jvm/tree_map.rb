# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/jvm/types"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    module JVMTreeMapBackend
      Key            = Struct.new(:key, :mutation_owner)
      Value          = Data.define(:value)
      KEY_COMPARATOR = JVMContainers.comparator do |left, right|
        next 0 if left.equal?(right)

        comparison = JVMContainers.compare(left.key, right.key)
        owner = left.mutation_owner || right.mutation_owner
        raise FrozenError, "can't modify frozen #{owner.class}" if owner&.__send__(:mutation_frozen?)
        comparison
      end

      INITIALIZATION_LOCK = Mutex.new
      State = Struct.new(:tree, :revision)
      private_constant :Key, :Value, :KEY_COMPARATOR, :INITIALIZATION_LOCK, :State

      def initialize(entries = nil)
        check_uninitialized

        parsed_entries = coerce_entries(entries)
        check_uninitialized
        guard = JVMOperationGuard.new(synchronized: synchronized?, label: "tree map")
        state = build_state(parsed_entries)

        if synchronized?
          guard.synchronize { publish_initialization(guard, state) }
        else
          publish_initialization(guard, state)
        end
      end

      def prepare_key(key) = canonical_key(key)

      def freeze
        state = @freeze_state
        return super unless synchronized? && state

        state.set
        self
      end

      def frozen?
        state = @freeze_state
        synchronized? && state ? state.value : super
      end

      def [](key)
        key = canonical_key(key)
        access do
          wrapped = JVMContainers.nullable(@state.tree.get(Key.new(key)))
          wrapped&.value
        end
      end

      def fetch(*arguments)
        unless arguments.length.between?(1, 2)
          raise ArgumentError, "wrong number of arguments (given #{arguments.length}, expected 1..2)"
        end

        original_key, default = arguments
        key = canonical_key(original_key)
        default_given = arguments.length == 2
        warn "block supersedes default value argument", uplevel: 1 if block_given? && default_given
        wrapped = access { JVMContainers.nullable(@state.tree.get(Key.new(key))) }
        return wrapped.value if wrapped
        return yield(original_key) if block_given?
        return default if default_given

        raise KeyError.new(
          "key not found: #{original_key.inspect}",
          receiver: self,
          key:      original_key,
        )
      end

      def key?(key)
        key = canonical_key(key)
        access { !JVMContainers.nullable(@state.tree.get(Key.new(key))).nil? }
      end

      def getkey(key)
        key = canonical_key(key)
        access do
          probe = Key.new(key)
          entry = JVMContainers.nullable(@state.tree.ceilingEntry(probe))
          next unless entry && KEY_COMPARATOR.compare(probe, entry.getKey).zero?

          entry.getKey.key
        end
      end

      def each
        return enum_for(__method__) { size } unless block_given?

        entries = access do
          snapshot = []
          iterator = @state.tree.entrySet.iterator
          while iterator.hasNext
            entry = iterator.next
            snapshot << [entry.getKey.key, entry.getValue.value]
          end
          snapshot
        end
        entries.each { yield it }
        self
      end

      def each_live
        return enum_for(__method__) { size } unless block_given?

        iterator = nil
        last_key = nil
        revision = nil
        started = false
        loop do
          pair = access do
            current = @state.revision
            if !started || revision != current
              entries = started ? @state.tree.tailMap(Key.new(last_key), false).entrySet : @state.tree.entrySet
              iterator = entries.iterator
            end
            next unless iterator.hasNext

            entry = iterator.next
            last_key = entry.getKey.key
            revision = current
            [last_key, entry.getValue.value]
          end
          break unless pair
          started = true
          yield pair
        end
        self
      end

      def []=(key, value)
        key = canonical_key(key)
        access do
          check_local_frozen
          wrapped_key = mutation_key(key)
          begin
            @state.tree.put(wrapped_key, Value.new(value))
            @state.revision += 1
          ensure
            Thread.handle_interrupt(INTERRUPT_MASK) do
              wrapped_key.mutation_owner = nil
            end
          end
          value
        end
      end

      def delete(key)
        key = canonical_key(key)
        access do
          check_local_frozen
          wrapped = JVMContainers.nullable(@state.tree.remove(mutation_key(key)))
          @state.revision += 1 if wrapped
          wrapped&.value
        end
      end

      def first_key
        access do
          entry = JVMContainers.nullable(@state.tree.firstEntry)
          entry&.getKey&.key
        end
      end

      def last_key
        access do
          entry = JVMContainers.nullable(@state.tree.lastEntry)
          entry&.getKey&.key
        end
      end

      def shift
        access do
          check_local_frozen
          iterator = @state.tree.entrySet.iterator
          next nil unless iterator.hasNext

          entry = iterator.next
          result = [entry.getKey.key, entry.getValue.value]
          iterator.remove
          @state.revision += 1
          result
        end
      end

      def pop
        access do
          check_local_frozen
          iterator = @state.tree.descendingMap.entrySet.iterator
          next nil unless iterator.hasNext

          entry = iterator.next
          result = [entry.getKey.key, entry.getValue.value]
          iterator.remove
          @state.revision += 1
          result
        end
      end

      def size = access { @state.tree.size }

      alias length size

      def empty? = access { @state.tree.isEmpty }

      def clear
        access do
          check_local_frozen
          unless @state.tree.isEmpty
            @state.tree.clear
            @state.revision += 1
          end
        end
        self
      end

      def initialize_copy(_other)
        raise TypeError, "tree maps cannot be copied"
      end

      private

      def publish_initialization(guard, state)
        INITIALIZATION_LOCK.synchronize do
          Thread.handle_interrupt(INTERRUPT_MASK) do
            raise "tree map is already initialized" if defined?(@state)
            raise FrozenError, "can't modify frozen #{self.class}" if
              JVMContainers.frozen_object?(self)

            @state = state
            @guard = guard
            @freeze_state = Flag.new(false) if synchronized?
            JVMContainers.freeze_object(self) if synchronized?
          end
        end
      end

      def access(&)
        raise "tree map is not initialized" unless defined?(@guard) && @guard

        @guard.synchronize(&)
      end

      def synchronized? = false

      def check_local_frozen
        raise FrozenError, "can't modify frozen #{self.class}" if mutation_frozen?
      end

      def mutation_frozen? = synchronized? ? frozen? : JVMContainers.frozen_object?(self)

      def mutation_key(key)
        Key.new(key, self)
      end

      def canonical_key(key)
        JVMContainers.string?(key) ? JVMContainers.canonical_string(key) : key
      end

      def build_state(entries)
        tree = JVMContainers::TreeMap.new(KEY_COMPARATOR)
        entries&.each do |key, value|
          check_uninitialized

          stored_key = canonical_key(key)
          check_uninitialized

          wrapped_key = Key.new(stored_key, self)
          begin
            tree.put(wrapped_key, Value.new(value))
          ensure
            Thread.handle_interrupt(INTERRUPT_MASK) do
              wrapped_key.mutation_owner = nil
            end
          end
          check_uninitialized
        end
        State.new(tree, 0)
      end

      def check_uninitialized
        raise "tree map is already initialized" if defined?(@state)
        raise FrozenError, "can't modify frozen #{self.class}" if JVMContainers.frozen_object?(self)
      end

      def coerce_entries(entries)
        return if entries.nil?
        return entries if JVMContainers.is_a?(entries, Hash)

        hash = entries.to_hash if entries.respond_to?(:to_hash)
        return hash if JVMContainers.is_a?(hash, Hash)

        raise TypeError, "entries must be a Hash or respond to #to_hash"
      end
    end

    # Explicit unsynchronized JVM implementation.
    class UnsafeTreeMap
      include JVMTreeMapBackend
    end

    # Default JVM implementation: ordinary TreeMap under a coarse lock. The
    # object itself is frozen, while its guarded Java backing map remains the
    # controlled mutation boundary.
    class TreeMap
      include JVMTreeMapBackend

      private

      def synchronized? = true
    end

    MutableTreeMap = TreeMap

    # No Ractors, no problems :)
    ShareableTreeMap = TreeMap

    private_constant :JVMTreeMapBackend
  end
end
