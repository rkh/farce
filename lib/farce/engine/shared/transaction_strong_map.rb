# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal # :nodoc: all
    module PortableTransaction
      # Keep the index identity so operations already resolving a key retry
      # against the installed entries. Retiring old cells invalidates queued
      # operations without adding checks to ordinary map methods.
      class StrongMapEntry < Entry
        FIELDS = %i[@data @entries @registry_holes @sweep_cursor @iteration_epoch].freeze
        CELL_FIELDS = %i[@retired @present @key @value].freeze

        # A transaction snapshot must not omit cells retired by a concurrent
        # commit. Lock the registry and captured cells, then recheck membership.
        def self.pairs(index)
          loop do
            cells = index.snapshot
            registry = index.instance_variable_get(:@registry_mutex)
            locks = [registry, *cells.map { it.instance_variable_get(:@mutex) }].sort_by(&:object_id)
            acquired = []
            Thread.handle_interrupt(INTERRUPT_MASK) do
              locked = locks.all? do |lock|
                lock.try_lock && acquired.push(lock)
              end
              if locked
                current = index.instance_variable_get(:@entries).compact
                if current.size == cells.size &&
                    current.each_index.all? { PortableTransaction.same?(current[it], cells[it]) }
                  return cells.filter_map do |cell|
                    next if cell.instance_variable_get(:@retired) || !cell.instance_variable_get(:@present)
                    alive, key = cell.instance_variable_get(:@key).read
                    [key, cell.instance_variable_get(:@value)] if alive
                  end
                end
              end
            ensure
              acquired.reverse_each(&:unlock)
            end
            if Fiber.respond_to?(:scheduler) && Fiber.scheduler
              Fiber.scheduler.kernel_sleep(0)
            else
              Thread.pass
            end
          end
        end

        # This entry coordinates index and cell locks rather than a single storage field.
        def initialize(source, working, _kind, baseline) # rubocop:disable Lint/MissingSuper
          @source, @working, @baseline = source, working, baseline
          @dirty = @applied = false
          @index = source.instance_variable_get(:@index)
          @index_lock = @index.instance_variable_get(:@lock)
        end

        def prepare
          @cells = @index.snapshot
          @locks = [@index_lock.instance_variable_get(:@mutex), @index.instance_variable_get(:@registry_mutex)]
          @locks.concat(@cells.map { it.instance_variable_get(:@mutex) })
          replacement = @working.instance_variable_get(:@index)
          @replacement = FIELDS.map { replacement.instance_variable_get(it) }
        end

        def valid?
          return false if @dirty && @source.frozen?
          return false if @index_lock.instance_variable_get(:@reserved)
          current = @index.instance_variable_get(:@entries).compact
          return false unless current.size == @cells.size &&
            current.each_index.all? { PortableTransaction.same?(current[it], @cells[it]) }
          return false unless @cells.size == @baseline.size
          return false unless @cells.all? do |cell|
            next false if cell.instance_variable_get(:@reserved) || cell.instance_variable_get(:@retired)
            next false unless cell.instance_variable_get(:@present)
            alive, key = cell.instance_variable_get(:@key).read
            alive && @baseline.key?(key) &&
              PortableTransaction.same?(@baseline[key], cell.instance_variable_get(:@value))
          end
          @original = FIELDS.map { @index.instance_variable_get(it) }
          @original_cells = @cells.map { |cell| CELL_FIELDS.map { cell.instance_variable_get(it) } }
          @replacement[-1] = @original[-1] + 1
          true
        end

        def apply
          return unless @dirty
          @applied = true
          FIELDS.each_with_index { |field, index| @index.instance_variable_set(field, @replacement[index]) }
          @cells.each do |cell|
            cell.instance_variable_set(:@retired, true)
            cell.instance_variable_set(:@present, false)
            cell.instance_variable_set(:@key, nil)
            cell.instance_variable_set(:@value, nil)
          end
        end

        def restore
          return unless @applied
          FIELDS.each_with_index { |field, index| @index.instance_variable_set(field, @original[index]) }
          @cells.each_with_index do |cell, index|
            CELL_FIELDS.each_with_index do |field, offset|
              cell.instance_variable_set(field, @original_cells[index][offset])
            end
          end
        end

        def notify
          return unless @dirty
          @index.change_signal.broadcast
          @cells.each do |cell|
            cell.instance_variable_get(:@changes)&.broadcast
            cell.instance_variable_get(:@signal)&.broadcast
          end
        end
      end
    end
  end
end
