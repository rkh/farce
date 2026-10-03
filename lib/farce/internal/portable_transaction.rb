# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal # :nodoc: all
    # Portable commits use existing mutexes. Validation compares original
    # storage by identity without invoking user equality or hash callbacks.
    module PortableTransaction
      include Autoloads

      def self.same?(left, right) = BasicObject.instance_method(:equal?).bind_call(left, right)

      def self.snapshot(source, kind)
        case kind
        when :atom
          value, version = source.instance_variable_get(:@mutex).synchronize do
            [source.instance_variable_get(:@value), source.instance_variable_get(:@version)]
          end
          working = source.class.new(value, compare_by_identity: source.compare_by_identity?)
          Entry.new(source, working, kind, version)
        when :vector
          values = source.snapshot
          working = source.class.new(values, compare_by_identity: source.compare_by_identity?)
          Entry.new(source, working, kind, values)
        when :map, :strong_map
          pairs = source.transaction_pairs
          working = source.class.new(
            compare_keys_by_identity:   source.compare_keys_by_identity?,
            compare_values_by_identity: source.compare_values_by_identity?,
          )
          pairs.each { |key, value| working[key] = value }
          baseline = {}.compare_by_identity
          pairs.each { |key, value| baseline[key] = value }
          entry_class = kind == :strong_map ? StrongMapEntry : Entry
          entry_class.new(source, working, kind, baseline)
        end
      end

      def self.commit(entries, guards = [])
        entries.each(&:prepare)
        locks = entries.flat_map(&:locks).uniq.sort_by(&:object_id)
        acquired = []
        begin
          locks.each do |lock|
            return false unless lock.try_lock
            acquired << lock
          end
          return false if guards.any?(&:value)
          return false unless entries.all?(&:valid?)
          begin
            entries.each(&:apply)
            unless !block_given? || yield
              entries.reverse_each(&:restore)
              return false
            end
          rescue Exception # rubocop:disable Lint/RescueException -- restore before propagating any interruption
            entries.reverse_each(&:restore)
            raise
          end
          true
        ensure
          acquired.reverse_each(&:unlock)
        end
      end

      class Entry
        attr_reader :working, :locks

        def initialize(source, working, kind, baseline)
          @source   = source
          @working  = working
          @kind     = kind
          @baseline = baseline
          @dirty    = false
          @applied  = false
          @field    = { atom: :@value, vector: :@values, map: :@map }.fetch(kind)
          @locks    = if kind == :map
                        %i[@reservation_mutex @state_mutex].map { source.instance_variable_get(it) }
                      else
                        [source.instance_variable_get(:@mutex)]
                      end
        end

        def write!
          @dirty = true
        end

        def prepare
          @replacement = @working.instance_variable_get(@field)
          @next_version = @baseline + 1 if @kind == :atom
        end

        def valid?
          frozen = @kind == :map ? @source.frozen? : @source.instance_variable_get(:@farce_frozen)
          return false if @dirty && frozen
          @original = @source.instance_variable_get(@field)
          case @kind
          when :atom
            !@source.instance_variable_get(:@updating) &&
              @source.instance_variable_get(:@version) == @baseline
          when :vector
            !@source.instance_variable_get(:@updating) && @original.size == @baseline.size &&
              @baseline.each_index.all? { PortableTransaction.same?(@original[it], @baseline[it]) }
          when :map
            return false unless @source.transaction_idle?
            pairs = @source.transaction_pairs
            pairs.size == @baseline.size && pairs.all? do |key, value|
              @baseline.key?(key) && PortableTransaction.same?(@baseline[key], value)
            end
          end
        end

        def apply
          return unless @dirty
          @applied = true
          @source.instance_variable_set(@field, @replacement)
          @source.instance_variable_set(:@version, @next_version) if @kind == :atom
        end

        # CRuby's Array iteration captures storage without its Ruby mutex.
        # Hide provisional replacements from newly starting iterators.
        def reserve
          return unless @kind == :vector
          @reserved = true
          @source.instance_variable_set(:@updating, :transaction)
        end

        def unreserve
          return unless @reserved
          @source.instance_variable_set(:@updating, false)
          @reserved = false
        end

        def restore
          return unless @applied
          @source.instance_variable_set(@field, @original)
          @source.instance_variable_set(:@version, @baseline) if @kind == :atom
        end

        def notify
          return unless @dirty
          signal = @source.instance_variable_get(@kind == :map ? :@change_signal : :@signal)
          if @kind == :atom
            @locks.first.synchronize { signal.broadcast }
          else
            signal.broadcast
          end
        end
      end

      # Validate only cardinality while ordinary map mutations are excluded by
      # the existing reservation and state locks. This entry never publishes data.
      class MapSizeEntry < Entry
        def initialize(source, size)
          super(source, nil, :map, size)
        end

        def prepare; end
        def valid? = @source.transaction_idle? && @source.size == @baseline
      end
    end
  end
end
