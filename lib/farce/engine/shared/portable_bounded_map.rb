# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Portable correctness backend for bounded maps confined to one Ractor.
    # Production engines may replace it with specialized storage.
    class PortableBoundedMap
      INITIALIZATION_LOCK = Lock.new
      private_constant :INITIALIZATION_LOCK

      class HashCode
        def initialize(value) = @value = value
        def hash              = @value

        def eql?(other)
          HashCode === other && Integer.instance_method(:==).bind_call(@value, other.value)
        end

        protected attr_reader :value
      end
      private_constant :HashCode

      class Node
        attr_accessor :key, :hash_code, :collision_index, :value, :previous, :following, :bucket

        def initialize(key, hash_code, value)
          @key             = key
          @hash_code       = hash_code
          @collision_index = nil
          @value           = value
          @previous        = nil
          @following       = nil
          @bucket          = nil
        end
      end
      private_constant :Node

      def initialize(
        max_size:,
        compare_by_identity: false,
        compare_keys_by_identity: compare_by_identity,
        compare_values_by_identity: compare_by_identity
      )
        check_initializable!
        validate_boolean(compare_by_identity, "compare_by_identity")
        validate_boolean(compare_keys_by_identity, "compare_keys_by_identity")
        validate_boolean(compare_values_by_identity, "compare_values_by_identity")
        validate_limit(max_size, "max_size")

        mutex = Mutex.new
        INITIALIZATION_LOCK.synchronize do
          commit do
            check_initializable!
            @initializing = true
            begin
              @max_size                   = max_size
              @compare_keys_by_identity   = compare_keys_by_identity
              @compare_values_by_identity = compare_values_by_identity
              @buckets                    = {}
              @size                       = 0
              @mutex                      = mutex
              @freeze_state               = Flag.new(false)
              initialize_policy
              @initialized = true
            ensure
              remove_instance_variable(:@initializing) if instance_variable_defined?(:@initializing)
            end
          end
        end
      end

      def initialize_copy(other)
        super
        other.send(:synchronize) do
          @max_size                   = other.instance_variable_get(:@max_size)
          @compare_keys_by_identity   = other.instance_variable_get(:@compare_keys_by_identity)
          @compare_values_by_identity = other.instance_variable_get(:@compare_values_by_identity)
          @mutex                      = Mutex.new
          @freeze_state               = Flag.new(false)
          @buckets                    = {}
          @size                       = 0
          initialize_policy
          copy_policy_nodes(other)
        end
      end

      def [](key)
        synchronize do
          node = find_node(key)
          return nil unless node
          unless frozen?
            prepared = policy_prepare_access(node)
            commit { policy_commit_access(node, prepared) }
          end
          node.value
        end
      end

      def freeze
        state = @freeze_state
        return super unless state

        state.set
        self
      end

      def frozen?
        state = @freeze_state
        state ? state.value : super
      end

      def []=(key, value)
        synchronize do
          check_mutable!
          if @max_size.zero?
            key_hash_code(canonical_key(key))
            check_mutable!
            next value
          end
          node = find_node(key)
          if node
            prepared = policy_prepare_access(node)
            check_mutable!
            commit do
              node.value = value
              policy_commit_access(node, prepared)
            end
          else
            victim               = policy_victim if @size >= @max_size
            stored_key           = canonical_key(key)
            hash_code            = key_hash_code(stored_key)
            node                 = Node.new(stored_key, hash_code, value)
            prepared             = policy_prepare_insert(node)
            bucket               = @buckets[hash_code]
            replacement_bucket   = bucket ? bucket.dup : []
            node.collision_index = replacement_bucket.length
            replacement_bucket << node
            check_mutable!

            commit do
              # The internal hash-code keys cannot invoke user callbacks. Replacing a
              # prepared collision chain happens before callback-free eviction.
              @buckets[hash_code] = replacement_bucket
              @size += 1
              policy_commit_insert(node, prepared)
              remove_node(victim) if victim
            end
          end
          value
        end
      end

      def fetch(*arguments)
        unless arguments.length.between?(1, 2)
          raise ArgumentError, "wrong number of arguments (given #{arguments.length}, expected 1..2)"
        end

        key, default  = arguments
        default_given = arguments.length == 2

        warn "block supersedes default value argument", uplevel: 1 if block_given? && default_given

        found, value = synchronize do
          node = find_node(key)
          if node
            unless frozen?
              prepared = policy_prepare_access(node)
              commit { policy_commit_access(node, prepared) }
            end
            [true, node.value]
          else
            [false, nil]
          end
        end

        return value if found
        return yield(key) if block_given?
        return default if default_given

        raise KeyError.new("key not found: #{key.inspect}", receiver: self, key: key)
      end

      def prepare_key(key)
        synchronize do
          stored_key = canonical_key(key)
          find_node(stored_key)
          stored_key
        end
      end

      def key?(key) = synchronize { !find_node(key).nil? }

      def getkey(key)
        synchronize { find_node(key)&.key }
      end

      def delete(key)
        synchronize do
          check_mutable!
          node = find_node(key)
          if node
            check_mutable!
            commit { remove_node(node).value }
          end
        end
      end

      def clear
        synchronize do
          check_mutable!
          commit do
            @buckets.clear
            @size = 0
            policy_clear
          end
        end
        self
      end

      def max_size = synchronize { @max_size }

      def max_size=(limit)
        validate_limit(limit, "max_size")
        synchronize do
          check_mutable!
          commit do
            remove_victims_until(limit)
            @max_size = limit
          end
        end
        limit
      end

      def prune(to:)
        validate_limit(to, "to")
        synchronize do
          check_mutable!
          original_size = @size
          commit { remove_victims_until(to) }
          original_size - @size
        end
      end

      def shift
        synchronize do
          check_mutable!
          node = policy_victim
          node ? commit { remove_node(node).then { [it.key, it.value] } } : nil
        end
      end

      def empty? = synchronize { @size.zero? }
      def size   = synchronize { @size }
      alias length size

      def compare_keys_by_identity?   = synchronize { @compare_keys_by_identity }
      def compare_values_by_identity? = synchronize { @compare_values_by_identity }

      def each(&block)
        return enum_for(__method__) unless block_given?
        snapshot.each { block.call(*it) }
        self
      end
      alias each_pair each

      def each_key(&block)
        return enum_for(__method__) unless block_given?
        snapshot.each { block.call(it.first) }
        self
      end

      def each_value(&block)
        return enum_for(__method__) unless block_given?
        snapshot.each { block.call(it.last) }
        self
      end

      def keys = snapshot.map!(&:first).freeze

      private

      def check_initializable!
        if instance_variable_defined?(:@initializing) || instance_variable_defined?(:@initialized)
          raise "bounded map is already initialized"
        end
        raise FrozenError, "can't modify frozen #{self.class}" if frozen?
      end

      def synchronize(&)
        raise "bounded map is not initialized" unless instance_variable_defined?(:@initialized)

        @mutex.synchronize(&)
      end

      def check_mutable! = Internal::Freeze.check(self)

      def find_node(key)
        hash_code = key_hash_code(key)
        @buckets[hash_code]&.find { keys_equal?(it.key, key) }
      end

      def primitive_id(value) = BasicObject.instance_method(:__id__).bind_call(value)

      def key_hash_code(key)
        hash = @compare_keys_by_identity ? primitive_id(key) : key.hash
        hash = Integer.try_convert(hash) unless Integer === hash
        raise TypeError, "hash value must be an Integer" unless hash
        HashCode.new(hash)
      end

      def keys_equal?(stored, probe)
        identical = BasicObject.instance_method(:equal?).bind_call(stored, probe)
        return true if identical
        !@compare_keys_by_identity && stored.eql?(probe)
      end

      def canonical_key(key) = !@compare_keys_by_identity && String === key ? canonical_string(key) : key

      def canonical_string(string)
        klass = Object.instance_method(:class).bind_call(string)
        if BasicObject.instance_method(:equal?).bind_call(klass, String)
          return String.instance_method(:-@).bind_call(string)
        end

        copy = Class.instance_method(:allocate).bind_call(klass)
        String.instance_method(:replace).bind_call(copy, string)
        Object.instance_method(:instance_variables).bind_call(string).each do |name|
          value = Object.instance_method(:instance_variable_get).bind_call(string, name)
          Object.instance_method(:instance_variable_set).bind_call(copy, name, value)
        end
        Object.instance_method(:freeze).bind_call(copy)
      end

      def remove_node(node)
        policy_remove(node)
        bucket = @buckets.fetch(node.hash_code)
        index = node.collision_index
        last = bucket.pop
        unless BasicObject.instance_method(:equal?).bind_call(last, node)
          bucket[index] = last
          last.collision_index = index
        end
        node.collision_index = nil
        @buckets.delete(node.hash_code) if bucket.empty?
        @size -= 1
        node
      end

      def copy_node(node)
        copy = Node.new(node.key, node.hash_code, node.value)
        bucket = (@buckets[node.hash_code] ||= [])
        copy.collision_index = bucket.length
        bucket << copy
        @size += 1
        copy
      end

      def remove_victims_until(target)
        remove_node(policy_victim) while @size > target
      end

      def snapshot
        synchronize do
          @buckets.each_value.flat_map { |bucket| bucket.map { [it.key, it.value] } }
        end
      end

      def validate_boolean(value, name)
        equal = BasicObject.instance_method(:equal?)
        return if equal.bind_call(value, true) || equal.bind_call(value, false)
        raise ArgumentError, "#{name} must be true or false"
      end

      def validate_limit(value, name)
        raise TypeError, "#{name} must be an Integer" unless Integer === value
        raise ArgumentError, "#{name} must be non-negative" if value.negative?
      end

      def commit(&) = Thread.handle_interrupt(INTERRUPT_MASK, &)

      # Policy hooks are deliberately separate from the public storage protocol.
      def initialize_policy = raise NotImplementedError
      def policy_clear = raise NotImplementedError
      def policy_commit_access(node, prepared) = raise NotImplementedError
      def policy_commit_insert(node, prepared) = raise NotImplementedError
      def policy_prepare_access(node) = raise NotImplementedError
      def policy_prepare_insert(node) = raise NotImplementedError
      def policy_remove(node) = raise NotImplementedError
      def policy_victim = raise NotImplementedError
      def copy_policy_nodes(_other) = raise NotImplementedError
    end

    class PortableLRUMap < PortableBoundedMap
      private

      def initialize_policy
        @least_recent = nil
        @most_recent = nil
      end

      def copy_policy_nodes(other)
        node = other.instance_variable_get(:@least_recent)
        while node
          append(copy_node(node))
          node = node.following
        end
      end

      def policy_prepare_access(_node) = nil
      def policy_prepare_insert(_node) = nil

      def policy_commit_access(node, _prepared)
        return if node.equal?(@most_recent)
        unlink(node)
        append(node)
      end

      def policy_commit_insert(node, _prepared) = append(node)

      def policy_remove(node) = unlink(node)
      def policy_victim = @least_recent

      def policy_clear
        @least_recent = nil
        @most_recent = nil
      end

      def append(node)
        node.previous = @most_recent
        node.following = nil
        @most_recent.following = node if @most_recent
        @least_recent ||= node
        @most_recent = node
      end

      def unlink(node)
        if node.previous
          node.previous.following = node.following
        else
          @least_recent = node.following
        end
        if node.following
          node.following.previous = node.previous
        else
          @most_recent = node.previous
        end
        node.previous = nil
        node.following = nil
      end
    end

    # Adds the public strict-map key and value contract to portable storage.
    module PortableStrictBoundedMap
      def [](key) = super(strict_key(key))

      def []=(key, value)
        super(strict_key(key), strict_value(value))
      end

      def fetch(*arguments, &)
        strict_key(arguments.first) unless arguments.empty?
        super
      end

      def prepare_key(key) = super(strict_key(key))
      def key?(key) = super(strict_key(key))
      def getkey(key) = super(strict_key(key))
      def delete(key) = super(strict_key(key))

      private

      def strict_key(key)
        key = canonical_key(key)
        return key if Ractor.shareable?(key)
        raise Ractor::IsolationError, "key must be Ractor-shareable"
      end

      def strict_value(value)
        return value unless Internal.native_ractors?
        return value if Ractor.shareable?(value)
        raise Ractor::IsolationError, "value must be Ractor-shareable"
      end
    end
    private_constant :PortableStrictBoundedMap

    class PortableStrictLRUMap < PortableLRUMap
      include PortableStrictBoundedMap
    end

    class PortableLFUMap < PortableBoundedMap
      class Bucket
        attr_accessor :frequency, :previous, :following, :least_recent, :most_recent

        def initialize(frequency)
          @frequency = frequency
          @previous = nil
          @following = nil
          @least_recent = nil
          @most_recent = nil
        end

        def empty? = least_recent.nil?
      end
      private_constant :Bucket

      private

      def initialize_policy
        @least_frequent = nil
      end

      def copy_policy_nodes(other)
        source_bucket = other.instance_variable_get(:@least_frequent)
        previous = nil
        while source_bucket
          bucket = Bucket.new(source_bucket.frequency)
          bucket.previous = previous
          previous.following = bucket if previous
          @least_frequent ||= bucket
          node = source_bucket.least_recent
          while node
            append_to_bucket(copy_node(node), bucket)
            node = node.following
          end
          previous = bucket
          source_bucket = source_bucket.following
        end
      end

      def policy_prepare_insert(_node)
        return @least_frequent if @least_frequent&.frequency == 1
        Bucket.new(1)
      end

      def policy_commit_insert(node, bucket)
        unless bucket.equal?(@least_frequent)
          bucket.following = @least_frequent
          @least_frequent.previous = bucket if @least_frequent
          @least_frequent = bucket
        end
        append_to_bucket(node, bucket)
      end

      def policy_prepare_access(node)
        source = node.bucket
        frequency = source.frequency + 1
        following = source.following
        return following if following&.frequency == frequency
        Bucket.new(frequency)
      end

      def policy_commit_access(node, destination)
        source = node.bucket
        unless destination.equal?(source.following)
          destination.previous = source
          destination.following = source.following
          source.following.previous = destination if source.following
          source.following = destination
        end
        unlink_from_bucket(node)
        remove_bucket(source) if source.empty?
        append_to_bucket(node, destination)
      end

      def policy_remove(node)
        bucket = node.bucket
        unlink_from_bucket(node)
        remove_bucket(bucket) if bucket.empty?
      end

      def policy_victim = @least_frequent&.least_recent
      def policy_clear = @least_frequent = nil

      def append_to_bucket(node, bucket)
        node.bucket = bucket
        node.previous = bucket.most_recent
        node.following = nil
        bucket.most_recent.following = node if bucket.most_recent
        bucket.least_recent ||= node
        bucket.most_recent = node
      end

      def unlink_from_bucket(node)
        bucket = node.bucket
        if node.previous
          node.previous.following = node.following
        else
          bucket.least_recent = node.following
        end
        if node.following
          node.following.previous = node.previous
        else
          bucket.most_recent = node.previous
        end
        node.previous = nil
        node.following = nil
        node.bucket = nil
      end

      def remove_bucket(bucket)
        if bucket.previous
          bucket.previous.following = bucket.following
        else
          @least_frequent = bucket.following
        end
        bucket.following.previous = bucket.previous if bucket.following
        bucket.previous = nil
        bucket.following = nil
      end
    end

    class PortableStrictLFUMap < PortableLFUMap
      include PortableStrictBoundedMap
    end
  end
end
