# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Shared coordination for indexes. Reference ownership belongs to the
    # concrete index and cell classes, never to flags in this class.
    class UnsharedWeakMapIndex
      attr_reader :change_signal

      def initialize
        @lock            = UnsharedWeakMapLock.new
        @registry_mutex  = Mutex.new
        @change_signal   = Signal.new
        @sweep_cursor    = 0
        @iteration_epoch = 0
        @registry_holes  = 0
        reset
      end

      def resolve(key, deadline: nil, create: false)
        completed, result = @lock.synchronize(deadline) do
          data = data_for(key)
          indexed_key = index_key(key)
          entry = data[indexed_key]
          if entry
            retired, = entry.retire_if_dead
            if retired || entry.retired?
              data.delete(indexed_key)
              forget(entry)
              entry = nil
            end
          end
          created = false
          if !entry && create
            begin
              entry = yield(key_reference(key))
              data[indexed_key] = entry
              register(entry)
              created = true
              @change_signal.broadcast
            ensure
              unless created
                entry&.retire
                entry&.release
              end
            end
          end
          [entry, created]
        end
        completed ? result : [nil, :timed_out]
      end

      def remove(key, entry)
        @lock.synchronize do
          unlink(entry, key)
          forget(entry)
        end
        @change_signal.broadcast
      end

      def clear
        _, entries = @lock.synchronize do
          entries = snapshot
          reset
          entries
        end
        entries.each(&:retire)
        @change_signal.broadcast
      end

      def sweep(entries)
        stale = entries.reject { it.lookup_key.first }
        return if stale.empty?
        @lock.synchronize { stale.each { sweep_entry(it) } }
      end

      def sweep_one
        entry = @registry_mutex.synchronize do
          next if @entries.empty?
          @sweep_cursor %= @entries.size
          @entries[@sweep_cursor].tap { @sweep_cursor += 1 }
        end
        return unless entry && !entry.lookup_key.first
        @lock.try_synchronize { sweep_entry(entry) }
      end

      def snapshot = @registry_mutex.synchronize { @entries.compact }

      def live_cursor
        @registry_mutex.synchronize do
          [registry_enumerator, @iteration_epoch]
        end
      end

      def next_live(cursor)
        @registry_mutex.synchronize do
          raise "map structurally changed during live iteration" if cursor[1] != @iteration_epoch
          while (entry = cursor[0].next).nil?
            # Deletion leaves a hole while an array cursor is active.
          end
          entry
        end
      end

      def close_cursor(cursor)
        cursor[0] = nil
      end

      private

      def data_for(_key) = @data
      def index_key(key) = key
      def key_reference(key) = UnsharedWeakMapReference.new(key)
      def registry_enumerator = @entries.to_enum(:each)

      def register(entry)
        @registry_mutex.synchronize do
          @iteration_epoch += 1
          @entries << entry
        end
      end

      def forget(entry)
        @registry_mutex.synchronize do
          if (index = @entries.index(entry))
            @entries[index] = nil
            @registry_holes += 1
            if @registry_holes > @entries.size / 4
              # Existing cursors keep their old array. Retired cells release
              # their keys and values, so abandoning a cursor retains no
              # registration in the map and requires no finalizer.
              @entries = @entries.compact
              @registry_holes = 0
            end
          end
        end
      end

      def sweep_entry(entry)
        retired, alive, key = entry.retire_if_dead
        return unless retired
        unlink(entry, key) if alive
        forget(entry)
        @change_signal.broadcast
      end

      def unlink(entry, key)
        data = data_for(key)
        indexed_key = index_key(key)
        data.delete(indexed_key) if data[indexed_key].equal?(entry)
      end
    end
    private_constant :UnsharedWeakMapIndex

    # WeakKeyMap is the only owner of heap-keyed cells. The enumerable registry
    # is weak and cannot prolong a cell's lifetime. Immediate keys need a Hash.
    # Comparison and cleanup follow the primitive. JRuby currently uses ==
    # instead of eql?, and JVM runtimes defer stale value cleanup until access.
    class UnsharedWeakKeyMapIndex < UnsharedWeakMapIndex
      def snapshot = @registry_mutex.synchronize { @entries.values }

      def sweep_one
        return unless @entries.respond_to?(:sweep_one)
        @registry_mutex.synchronize { @entries.sweep_one }
      end

      private

      def reset
        @data = ObjectSpace::WeakKeyMap.new
        @immediate = {}
        @registry_mutex.synchronize do
          @entries = if Internal.const_defined?(:ConcurrentWeakRegistry, false)
                       ConcurrentWeakRegistry.new
                     else
                       ObjectSpace::WeakMap.new
                     end
          @iteration_epoch += 1
        end
      end

      def data_for(key) = Internal.garbage_collectable?(key) ? @data : @immediate
      def key_reference(key) = UnsharedWeakMapWeakReference.for(key)
      def registry_enumerator = @entries.to_enum(:each_value)

      def register(entry)
        @registry_mutex.synchronize do
          @iteration_epoch += 1
          @entries[entry.token] = entry
        end
      end

      def forget(entry) = @registry_mutex.synchronize { @entries.delete(entry.token) }
    end
    private_constant :UnsharedWeakKeyMapIndex

    # WeakMap has weak values too, so this index must retain its cells. Its
    # strong side is reclaimed by housekeeping after an identity key disappears.
    class UnsharedWeakIdentityMapIndex < UnsharedWeakMapIndex
      private

      def reset
        @data = ObjectSpace::WeakMap.new
        @registry_mutex.synchronize do
          @entries = []
          @registry_holes = 0
          @iteration_epoch += 1
        end
      end

      def key_reference(key) = UnsharedWeakMapWeakReference.for(key)
    end
    private_constant :UnsharedWeakIdentityMapIndex

    class UnsharedStrongKeyMapIndex < UnsharedWeakMapIndex
      private

      def reset
        @data = {}
        @registry_mutex.synchronize do
          @entries = []
          @registry_holes = 0
          @iteration_epoch += 1
        end
      end
    end
    private_constant :UnsharedStrongKeyMapIndex

    class UnsharedStrongIdentityMapIndex < UnsharedStrongKeyMapIndex
      # Ruby numeric identity can differ from a JVM object's identity.
      class Key
        attr_reader :value

        def initialize(value) = @value = value
        def hash = BasicObject.instance_method(:__id__).bind_call(value)
        def eql?(other) = other.is_a?(Key) && BasicObject.instance_method(:equal?).bind_call(value, other.value)
      end
      private_constant :Key

      private

      def index_key(key) = Key.new(key)
    end
    private_constant :UnsharedStrongIdentityMapIndex
  end
end
