# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal # :nodoc: all
    # Records map dependencies without copying unobserved entries during the block.
    # Full-map operations validate those dependencies before capturing all entries.
    # Commit overlays staged writes onto a current snapshot for atomic publication.
    class TransactionMapSnapshot
      ABSENT = Object.new.freeze
      private_constant :ABSENT

      def initialize(source)
        @source = source
        @partial = source.class.new(
          compare_keys_by_identity:   source.compare_keys_by_identity?,
          compare_values_by_identity: source.compare_values_by_identity?,
        )
        @observations = {}
        @writes = {}
        if source.compare_keys_by_identity?
          @observations.compare_by_identity
          @writes.compare_by_identity
        end
        @observed_present = 0
        @base_size = nil
        @dirty = false
        @full = nil
      end

      def working = self

      def write!
        @dirty = true
        @full&.write!
      end

      def [](key)                                     = observe(key)[key]
      def key?(key)                                   = observe(key).key?(key)
      def store(key, value)                           = changed(key).store(key, value)
      def swap(key, value)                            = changed(key).swap(key, value)
      def compare_and_set(key, expected, replacement) = changed(key).compare_and_set(key, expected, replacement)

      def delete(key)
        map = changed(key)
        @writes[key] = true unless @full
        map.delete(key)
      end

      def size
        return @full.working.size if @full
        @base_size ||= @source.respond_to?(:transaction_size) ? @source.transaction_size : @source.size
        @base_size + @partial.size - @observed_present
      end

      def getkey(key) = promote.working.getkey(key)
      def keys = promote.working.keys
      def clear = promote.working.clear
      def each(&) = promote.working.each(&)

      def prepare_commit
        return @full if @full
        if !@dirty && @observations.empty?
          return unless @base_size
          return @source.transaction_size_snapshot(@base_size) if @source.respond_to?(:transaction_size_snapshot)
        end
        promote
      end

      private

      def read(source, key)
        return source.transaction_read(key) if source.respond_to?(:transaction_read)
        value = source.fetch(key, ABSENT)
        [!PortableTransaction.same?(value, ABSENT), value]
      end

      def observe(key)
        return @full.working if @full
        unless @observations.key?(key)
          present, value = read(@source, key)
          @observations[key] = [present, value]
          if present
            @partial.store(key, value)
            @observed_present += 1
          end
        end
        @partial
      end

      def changed(key)
        map = observe(key)
        @writes[key] = false unless @full || @writes.key?(key)
        map
      end

      def promote
        return @full if @full
        snapshot = @source.transaction_snapshot
        current = snapshot.working
        raise TransactionConflict, "map size changed" if @base_size && current.size != @base_size
        @observations.each do |key, (present, value)|
          current_present, current_value = read(current, key)
          unless present == current_present && (!present || PortableTransaction.same?(value, current_value))
            raise TransactionConflict, "map observation changed"
          end
        end
        @writes.each do |key, deleted|
          # Deletion followed by reinsertion must replace the stored key object.
          current.delete(key) if deleted
          if @partial.key?(key)
            current.store(@partial.getkey(key), @partial[key])
          else
            current.delete(key)
          end
        end
        snapshot.write! if @dirty
        @full = snapshot
      end
    end
  end
end
