# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/jvm/types"
require "farce/engine/jvm/extension"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    module JVMBoundedMapBackend
      Box                     = Struct.new(:value)
      State                   = Data.define(:core)
      INITIALIZATION_LOCK     = Mutex.new
      JAVA_CAPACITY_MAX       = (1 << 63) - 1
      INTEGER_XOR_METHOD      = Integer.instance_method(:^)
      INTEGER_SHIFT_METHOD    = Integer.instance_method(:>>)
      INTEGER_AND_METHOD      = Integer.instance_method(:&)
      INTEGER_SUBTRACT_METHOD = Integer.instance_method(:-)
      IDENTITY                = lambda do |stored, requested|
        JVMContainers.identical?(stored.value, requested.value)
      end

      EQUALITY = lambda do |stored, requested|
        left   = stored.value
        right  = requested.value
        next true if JVMContainers.identical?(left, right)
        next false unless left.eql?(right)

        true
      end
      private_constant :Box, :State, :INITIALIZATION_LOCK,
        :JAVA_CAPACITY_MAX, :INTEGER_XOR_METHOD, :INTEGER_SHIFT_METHOD,
        :INTEGER_AND_METHOD, :INTEGER_SUBTRACT_METHOD, :IDENTITY, :EQUALITY

      def initialize(
        entries = nil,
        max_size:,
        compare_by_identity: false,
        compare_keys_by_identity: compare_by_identity,
        compare_values_by_identity: compare_by_identity
      )
        check_initializable
        strict_boolean(compare_by_identity, "compare_by_identity")
        compare_keys_by_identity   = strict_boolean(compare_keys_by_identity, "compare_keys_by_identity")
        compare_values_by_identity = strict_boolean(compare_values_by_identity, "compare_values_by_identity")

        limit   = normalize_limit(max_size, "max_size")
        entries = coerce_entries(entries)
        check_initializable

        guard = JVMOperationGuard.new(synchronized: true, label: "bounded map")
        equal = compare_keys_by_identity ? IDENTITY : EQUALITY
        core  = JVMExtension::BoundedMap.new(lfu_policy?, limit, equal)

        entries&.each do |key, value|
          check_initializable
          key  = canonical_key(key, compare_keys_by_identity)
          hash = key_hash(key, compare_keys_by_identity)
          core.put(Box.new(key), Box.new(value), hash)
          check_initializable
        end

        state = State.new(core)

        INITIALIZATION_LOCK.synchronize do
          Thread.handle_interrupt(INTERRUPT_MASK) do
            check_initializable
            @compare_keys_by_identity   = compare_keys_by_identity
            @compare_values_by_identity = compare_values_by_identity
            @guard = guard
            @state = state
            JVMContainers.freeze_object(self)
          end
        end
      end

      def [](key)
        key     = canonical_key(key)
        wrapped = access { core.get(Box.new(key), key_hash(key)) }
        JVMContainers.nullable(wrapped)&.value
      end

      def []=(key, value)
        key = canonical_key(key)
        access { core.put(Box.new(key), Box.new(value), key_hash(key)) }
        value
      end

      def fetch(*arguments)
        unless arguments.length.between?(1, 2)
          raise ArgumentError, "wrong number of arguments (given #{arguments.length}, expected 1..2)"
        end

        original_key, default = arguments
        key                   = canonical_key(original_key)
        default_given         = arguments.length == 2

        warn "block supersedes default value argument", uplevel: 1 if block_given? && default_given

        wrapped = access { core.get(Box.new(key), key_hash(key)) }
        wrapped = JVMContainers.nullable(wrapped)

        return wrapped.value       if wrapped
        return yield(original_key) if block_given?
        return default             if default_given

        raise KeyError.new(
          "key not found: #{original_key.inspect}",
          receiver: self,
          key:      original_key,
        )
      end

      def prepare_key(key)
        key = canonical_key(key)
        access { core.observeKey(Box.new(key), key_hash(key)) }
        key
      end

      def key?(key)
        key = canonical_key(key)
        !JVMContainers.nullable(access { core.observeKey(Box.new(key), key_hash(key)) }).nil?
      end

      def getkey(key)
        key     = canonical_key(key)
        wrapped = access { core.observeKey(Box.new(key), key_hash(key)) }
        JVMContainers.nullable(wrapped)&.value
      end

      def delete(key)
        key     = canonical_key(key)
        wrapped = access { core.delete(Box.new(key), key_hash(key)) }
        JVMContainers.nullable(wrapped)&.value
      end

      def clear
        access { core.clear }
        self
      end

      def max_size = access { core.getMaxSize }

      def max_size=(limit)
        limit = normalize_limit(limit, "max_size")
        access { core.setMaxSize(limit) }
        limit
      end

      def prune(to:)
        limit = normalize_limit(to, "to")
        access { core.prune(limit) }
      end

      def shift
        pair = JVMContainers.nullable(access { core.shift })
        [pair[0].value, pair[1].value] if pair
      end

      def empty? = access { core.isEmpty }
      def size   = access { core.size }
      alias length size

      def compare_keys_by_identity?   = @compare_keys_by_identity
      def compare_values_by_identity? = @compare_values_by_identity

      def each
        return enum_for(__method__) { size } unless block_given?

        snapshot = access { core.snapshot }
        index    = 0

        while index < snapshot.length
          yield snapshot[index].value, snapshot[index + 1].value
          index += 2
        end

        self
      end

      def each_key
        return enum_for(__method__) { size } unless block_given?
        each { |key, _value| yield key }
        self
      end

      def each_value
        return enum_for(__method__) { size } unless block_given?
        each { |_key, value| yield value }
        self
      end

      def initialize_copy(other)
        super
        other.send(:access) do
          @compare_keys_by_identity   = other.compare_keys_by_identity?
          @compare_values_by_identity = other.compare_values_by_identity?
          @guard = JVMOperationGuard.new(synchronized: true, label: "bounded map")
          @state = State.new(other.send(:core).copy)
          JVMContainers.freeze_object(self)
        end
      end

      private

      def access(&)
        raise "bounded map is not initialized" unless defined?(@guard) && @guard
        @guard.synchronize(&)
      end

      def core = @state.core

      def check_initializable
        raise "bounded map is already initialized" if defined?(@state)
        raise FrozenError, "can't modify frozen #{self.class}" if JVMContainers.frozen_object?(self)
      end

      def strict_boolean(value, name)
        return value if JVMContainers.identical?(value, true) || JVMContainers.identical?(value, false)
        raise ArgumentError, "#{name} must be a boolean"
      end

      def normalize_limit(value, name)
        raise TypeError, "#{name} must be an Integer" unless JVMContainers.is_a?(value, Integer)
        raise ArgumentError, "#{name} must be non-negative" if value.negative?
        raise RangeError, "#{name} exceeds the JVM backend limit" if value > JAVA_CAPACITY_MAX

        value
      end

      def canonical_key(key, identity = compare_keys_by_identity?)
        !identity && JVMContainers.string?(key) ? JVMContainers.canonical_string(key) : key
      end

      def key_hash(key, identity = compare_keys_by_identity?)
        value = identity ? JVMContainers.identity_token(key) : key.hash
        value = Integer.try_convert(value) unless JVMContainers.is_a?(value, Integer)
        raise TypeError, "hash value must be an Integer" unless value

        shifted = INTEGER_SHIFT_METHOD.bind_call(value, 32)
        folded  = INTEGER_XOR_METHOD.bind_call(value, shifted)
        folded  = INTEGER_AND_METHOD.bind_call(folded, 0xffff_ffff)
        return folded if folded < 0x8000_0000

        INTEGER_SUBTRACT_METHOD.bind_call(folded, 0x1_0000_0000)
      end

      def coerce_entries(entries)
        return if entries.nil?
        return entries if JVMContainers.is_a?(entries, Hash)

        hash = Hash.try_convert(entries)
        return hash if JVMContainers.is_a?(hash, Hash)

        raise TypeError, "entries must be a Hash or respond to #to_hash"
      end

      # simplecov:disable
      def lfu_policy? = raise "subclass failed to implement #lfu_policy?"
      # simplecov:enable
    end

    class LRUMap
      include JVMBoundedMapBackend

      private def lfu_policy? = false
    end

    class LFUMap
      include JVMBoundedMapBackend

      private def lfu_policy? = true
    end

    ShareableLRUMap = StrictLRUMap = LRUMap
    ShareableLFUMap = StrictLFUMap = LFUMap

    private_constant :JVMBoundedMapBackend
  end
end
