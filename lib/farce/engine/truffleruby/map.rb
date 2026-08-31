# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Map < TruffleRuby::ConcurrentMap
      alias concurrent_get []
      alias concurrent_store []=
      alias concurrent_clear clear
      alias concurrent_compute compute
      alias concurrent_compute_if_absent compute_if_absent
      alias concurrent_compute_if_present compute_if_present
      alias concurrent_delete delete
      alias concurrent_delete_pair delete_pair
      alias concurrent_each_pair each_pair
      alias concurrent_get_and_set get_and_set
      alias concurrent_get_or_default get_or_default
      alias concurrent_key? key?
      alias concurrent_merge_pair merge_pair
      alias concurrent_replace_if_exists replace_if_exists
      alias concurrent_replace_pair replace_pair
      alias concurrent_size size

      def initialize(
        initial_mapping = nil,
        compare_by_identity: false,
        compare_keys_by_identity: compare_by_identity,
        compare_values_by_identity: compare_by_identity
      )
        validate_boolean(compare_by_identity, "compare_by_identity")
        validate_boolean(compare_keys_by_identity, "compare_keys_by_identity")
        validate_boolean(compare_values_by_identity, "compare_values_by_identity")
        raise TypeError, "initial mapping must be a Hash" unless initial_mapping.nil? || initial_mapping.is_a?(Hash)

        super()
        @compare_keys_by_identity   = compare_keys_by_identity
        @compare_values_by_identity = compare_values_by_identity
        # Native operations may overlap; block updates reserve exclusive access.
        @state_mutex   = Mutex.new
        @state_signal  = Signal.new
        @change_signal = Signal.new
        @active        = 0
        @exclusive     = false
        initial_mapping&.each { |key, value| concurrent_store(wrap_key(key), value) }
      end

      def [](key) = concurrent_get(wrap_key(key))

      def fetch(*arguments)
        unless arguments.length.between?(1, 2)
          raise ArgumentError, "wrong number of arguments (given #{arguments.length}, expected 1..2)"
        end

        key, default = arguments
        default_given = arguments.length == 2
        warn "block supersedes default value argument", uplevel: 1 if block_given? && default_given
        missing = Object.new
        value = concurrent_get_or_default(wrap_key(key), missing)
        return value unless missing.equal?(value)
        return yield(key) if block_given?
        return default if default_given

        raise KeyError.new("key not found: #{key.inspect}", receiver: self, key: key)
      end

      def []=(key, value)
        _, result = with_operation(nil) do
          concurrent_store(wrap_key(key), value)
          changed!
          value
        end
        result
      end

      def get(key, timeout: nil, &fallback)
        completed, result = with_operation(timeout_deadline(timeout)) { concurrent_get(wrap_key(key)) }
        completed ? result : fallback&.call
      end

      def store(key, value, timeout: nil, &fallback)
        completed, result = with_operation(timeout_deadline(timeout)) do
          concurrent_store(wrap_key(key), value)
          changed!
          value
        end
        completed ? result : fallback&.call
      end

      def swap(key, replacement, timeout: nil, &fallback)
        completed, result = with_operation(timeout_deadline(timeout)) do
          previous = concurrent_get_and_set(wrap_key(key), replacement)
          changed!
          previous
        end
        completed ? result : fallback&.call
      end

      def store_if_absent(key, timeout: nil)
        raise LocalJumpError, "no block given" unless block_given?

        completed, result = with_exclusive_update(timeout_deadline(timeout)) do
          wrapped = wrap_key(key)
          if concurrent_key?(wrapped)
            concurrent_get(wrapped)
          else
            value = yield
            concurrent_store(wrapped, value)
            changed!
            value
          end
        end
        completed ? result : nil
      end

      def compare_and_set(key, expected, replacement, timeout: nil)
        completed, result = with_exclusive_update(timeout_deadline(timeout)) do
          wrapped = wrap_key(key)
          next false unless concurrent_key?(wrapped)

          current = concurrent_get(wrapped)
          next false unless values_equal?(current, expected)

          concurrent_store(wrapped, replacement)
          changed!
          true
        end
        completed && result
      end

      def update(key, timeout: nil)
        raise LocalJumpError, "no block given" unless block_given?

        completed, result = with_exclusive_update(timeout_deadline(timeout)) do
          wrapped = wrap_key(key)
          value = yield(concurrent_get(wrapped))
          concurrent_store(wrapped, value)
          changed!
          value
        end
        completed ? result : nil
      end

      def upsert(key, initial_value, timeout: nil)
        raise LocalJumpError, "no block given" unless block_given?

        completed, result = with_exclusive_update(timeout_deadline(timeout)) do
          wrapped = wrap_key(key)
          value = concurrent_key?(wrapped) ? yield(concurrent_get(wrapped)) : initial_value
          concurrent_store(wrapped, value)
          changed!
          value
        end
        completed ? result : nil
      end

      def wait_until_changed(key, expected, timeout: nil, &fallback)
        wait_for_value(key, expected, timeout_deadline(timeout), fallback, non_nil: false)
      end

      def wait_until_non_nil(key, timeout: nil, &fallback)
        wait_for_value(key, nil, timeout_deadline(timeout), fallback, non_nil: true)
      end

      def key?(key) = concurrent_key?(wrap_key(key))
      def size = concurrent_size
      def compare_keys_by_identity? = @compare_keys_by_identity
      def compare_values_by_identity? = @compare_values_by_identity

      def keys = entries_snapshot.map(&:first)

      def each(&block)
        return enum_for(__callee__) { size } unless block

        entries_snapshot.each { |pair| block.call(pair) }
        self
      end
      alias each_pair each

      def each_key(&block)
        return enum_for(__callee__) { size } unless block

        entries_snapshot.each { |pair| block.call(pair.first) }
        self
      end

      def each_value(&block)
        return enum_for(__callee__) { size } unless block

        entries_snapshot.each { |pair| block.call(pair.last) }
        self
      end

      def delete(key)
        _, result = with_operation(nil) do
          value = concurrent_delete(wrap_key(key))
          changed!
          value
        end
        result
      end

      def getkey(key)
        wrapped = wrap_key(key)
        return unless concurrent_key?(wrapped)

        concurrent_each_pair do |stored, _value|
          return unwrap_key(stored) if keys_equal?(stored, wrapped)
        end
        nil
      end

      def clear
        _, result = with_operation(nil) do
          concurrent_clear
          changed!
          self
        end
        result
      end

      def compute(key, &)
        _, result = with_exclusive_update(nil) do
          value = concurrent_compute(wrap_key(key), &)
          changed!
          value
        end
        result
      end

      def compute_if_absent(key, &)
        _, result = with_exclusive_update(nil) do
          value = concurrent_compute_if_absent(wrap_key(key), &)
          changed!
          value
        end
        result
      end

      def compute_if_present(key, &)
        _, result = with_exclusive_update(nil) do
          value = concurrent_compute_if_present(wrap_key(key), &)
          changed!
          value
        end
        result
      end

      def delete_pair(key, value)
        return delete_pair_by_identity(key, value) if compare_values_by_identity?

        _, result = with_operation(nil) do
          deleted = concurrent_delete_pair(wrap_key(key), value)
          changed! if deleted
          deleted
        end
        result
      end

      def get_and_set(key, value)
        _, result = with_operation(nil) do
          previous = concurrent_get_and_set(wrap_key(key), value)
          changed!
          previous
        end
        result
      end

      def get_or_default(key, default) = concurrent_get_or_default(wrap_key(key), default)

      def merge_pair(key, value, &)
        _, result = with_exclusive_update(nil) do
          merged = concurrent_merge_pair(wrap_key(key), value, &)
          changed!
          merged
        end
        result
      end

      def replace_if_exists(key, value)
        _, result = with_operation(nil) do
          previous = concurrent_replace_if_exists(wrap_key(key), value)
          changed!
          previous
        end
        result
      end

      def replace_pair(key, expected, replacement)
        return replace_pair_by_identity(key, expected, replacement) if compare_values_by_identity?

        _, result = with_operation(nil) do
          replaced = concurrent_replace_pair(wrap_key(key), expected, replacement)
          changed! if replaced
          replaced
        end
        result
      end

      private

      def wrap_key(key) = compare_keys_by_identity? ? IdentityKey.new(key) : key
      def unwrap_key(key) = key.is_a?(IdentityKey) ? key.value : key

      def entries_snapshot
        entries = []
        concurrent_each_pair { |key, value| entries << [unwrap_key(key), value] }
        entries
      end

      def keys_equal?(left, right)
        compare_keys_by_identity? ? left.eql?(right) : left.hash == right.hash && left.eql?(right)
      end

      def delete_pair_by_identity(key, expected)
        _, result = with_exclusive_update(nil) do
          wrapped = wrap_key(key)
          next false unless concurrent_key?(wrapped) && concurrent_get(wrapped).equal?(expected)

          concurrent_delete(wrapped)
          changed!
          true
        end
        result
      end

      def replace_pair_by_identity(key, expected, replacement)
        _, result = with_exclusive_update(nil) do
          wrapped = wrap_key(key)
          next false unless concurrent_key?(wrapped) && concurrent_get(wrapped).equal?(expected)

          concurrent_store(wrapped, replacement)
          changed!
          true
        end
        result
      end

      def validate_boolean(value, name)
        return if value.equal?(true) || value.equal?(false)
        raise ArgumentError, "#{name} must be true or false"
      end

      def with_operation(deadline)
        entered = enter_operation(deadline)
        return [false, nil] unless entered
        [true, yield]
      ensure
        leave_operation if entered
      end

      def enter_operation(deadline)
        while true # rubocop:disable Style/InfiniteLoop
          generation = @state_signal.generation
          entered = @state_mutex.synchronize do
            next false if @exclusive
            @active += 1
            true
          end
          return true if entered
          return false unless wait_for_signal(@state_signal, generation, deadline)
        end
      end

      def leave_operation
        notify = @state_mutex.synchronize do
          @active -= 1
          @active.zero?
        end
        @state_signal.broadcast if notify
      end

      def with_exclusive_update(deadline)
        entered = enter_exclusive_update(deadline)
        return [false, nil] unless entered
        [true, yield]
      ensure
        leave_exclusive_update if entered
      end

      def enter_exclusive_update(deadline)
        while true # rubocop:disable Style/InfiniteLoop
          generation = @state_signal.generation
          entered = @state_mutex.synchronize do
            next false if @exclusive || !@active.zero?
            @exclusive = true
          end
          return true if entered
          return false unless wait_for_signal(@state_signal, generation, deadline)
        end
      end

      def leave_exclusive_update
        @state_mutex.synchronize { @exclusive = false }
        @state_signal.broadcast
      end

      def changed! = @change_signal.broadcast

      def wait_for_value(key, expected, deadline, fallback, non_nil:)
        while true # rubocop:disable Style/InfiniteLoop
          generation = @change_signal.generation
          current = self[key]
          ready = non_nil ? !current.nil? : !values_equal?(current, expected)
          return current if ready
          return fallback&.call unless wait_for_signal(@change_signal, generation, deadline)
        end
      end

      def wait_for_signal(signal, generation, deadline)
        return signal.wait(generation) unless deadline

        remaining = deadline - Clock.now
        return false unless remaining.positive?
        !signal.wait(generation, timeout: remaining).nil?
      end

      def timeout_deadline(timeout)
        return if timeout.nil?

        timeout = Float(timeout)
        if !timeout.finite? || timeout.negative?
          raise ArgumentError, "timeout must be a finite, non-negative number or nil"
        end
        Clock.now + timeout
      end

      def values_equal?(left, right)
        compare_values_by_identity? ? left.equal?(right) : left == right
      end

      private :concurrent_get, :concurrent_store, :concurrent_clear, :concurrent_compute,
        :concurrent_compute_if_absent, :concurrent_compute_if_present, :concurrent_delete,
        :concurrent_delete_pair, :concurrent_each_pair, :concurrent_get_and_set,
        :concurrent_get_or_default, :concurrent_key?, :concurrent_merge_pair,
        :concurrent_replace_if_exists, :concurrent_replace_pair, :concurrent_size
    end
  end
end
