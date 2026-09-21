# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/jvm/types"
require "farce/engine/shared/weak_map/reference"

module Farce
  module Internal
    # Weak cell references in a registry whose iterator permits removal.
    # JRuby's ObjectSpace::WeakMap iterator fails when its registry changes.
    class ConcurrentWeakRegistry
      Holder = Data.define(:reference)
      private_constant :Holder

      def initialize
        @entries = JVMContainers::ConcurrentHashMap.new
        @sweep = nil
      end

      def []=(token, entry)
        @entries.put(token, Holder.new(UnsharedWeakMapWeakReference.for(entry)))
        sweep_one
        entry
      end

      def delete(token) = @entries.remove(token)

      def each_value
        return enum_for(__method__) unless block_given?
        iterator = @entries.entrySet.iterator
        while iterator.hasNext
          entry = iterator.next
          alive, cell = entry.getValue.reference.read
          if alive
            yield cell
          else
            @entries.remove(entry.getKey, entry.getValue)
          end
        end
        self
      end

      def values = each_value.to_a

      def sweep_one
        @sweep = @entries.entrySet.iterator unless @sweep&.hasNext
        return unless @sweep.hasNext
        entry = @sweep.next
        return if entry.getValue.reference.read.first
        @entries.remove(entry.getKey, entry.getValue)
      end
    end
  end
end
