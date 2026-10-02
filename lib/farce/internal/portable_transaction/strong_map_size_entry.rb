# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal # :nodoc: all
    module PortableTransaction
      # Validate a size-only read without comparing values. Keep the index locked
      # through publication so additions and removals wait. Cells created after
      # preparation use temporary locks. A live absent cell remains reserved by
      # its initializer and invalidates the attempt. Present or retired cells
      # cannot change membership without the index lock.
      class StrongMapSizeEntry < StrongMapEntry
        def initialize(source, size)
          super(source, nil, :strong_map, size)
        end

        def prepare
          capture_cells
          @cell_locks = {}.compare_by_identity
          @cells.each { @cell_locks[it.instance_variable_get(:@mutex)] = true }
        end

        def valid?
          return false if @index_lock.instance_variable_get(:@reserved)
          current  = @index.instance_variable_get(:@entries).compact
          acquired = []
          begin
            current.each do |cell|
              lock = cell.instance_variable_get(:@mutex)
              next if @cell_locks.key?(lock)
              return false unless lock.try_lock
              acquired << lock
            end
            return false if current.any? { it.instance_variable_get(:@reserved) }
            current.count { !it.instance_variable_get(:@retired) && it.instance_variable_get(:@present) } == @baseline
          ensure
            acquired.reverse_each(&:unlock)
          end
        end
      end
    end
  end
end
