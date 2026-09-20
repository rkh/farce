# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/shared/map_key_coordination"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Map < TruffleRuby::ConcurrentMap
      include MapKeyCoordination

      BASIC_OBJECT_EQUAL_METHOD = BasicObject.instance_method(:equal?)
      private_constant :BASIC_OBJECT_EQUAL_METHOD

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
        # Native operations may overlap. Block updates reserve one logical key.
        @state_mutex   = Mutex.new
        @change_signal = Signal.new
        @active_owner_fiber  = nil
        @active_owner_thread = nil
        @active_owners = nil
        initialize_key_coordination
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
        wrapped = wrap_key(key)
        _, result = with_key_operation(wrapped, nil) do |reservation|
          reservation.commit do
            native_operation { concurrent_store(wrapped, value) }
            changed!
          end
          value
        end
        result
      end

      def get(key, timeout: nil, &fallback)
        wrapped = wrap_key(key)
        completed, result = with_key_operation(wrapped, timeout_deadline(timeout)) do
          native_operation { concurrent_get(wrapped) }
        end
        completed ? result : fallback&.call
      end

      def store(key, value, timeout: nil, &fallback)
        wrapped = wrap_key(key)
        completed, result = with_key_operation(wrapped, timeout_deadline(timeout)) do |reservation|
          reservation.commit do
            native_operation { concurrent_store(wrapped, value) }
            changed!
          end
          value
        end
        completed ? result : fallback&.call
      end

      def swap(key, replacement, timeout: nil, &fallback)
        wrapped = wrap_key(key)
        completed, result = with_key_operation(wrapped, timeout_deadline(timeout)) do |reservation|
          previous = nil
          reservation.commit do
            previous = native_operation { concurrent_get_and_set(wrapped, replacement) }
            changed!
          end
          previous
        end
        completed ? result : fallback&.call
      end

      def store_if_absent(key, timeout: nil)
        raise LocalJumpError, "no block given" unless block_given?

        wrapped = wrap_key(key)
        completed, result = with_key_operation(wrapped, timeout_deadline(timeout)) do |reservation|
          if native_operation { concurrent_key?(wrapped) }
            native_operation { concurrent_get(wrapped) }
          else
            value = yield
            stored = reservation.commit do
              native_operation { concurrent_store(wrapped, value) }
              changed!
            end
            value if stored
          end
        end
        completed ? result : nil
      end

      def compare_and_set(key, expected, replacement, timeout: nil)
        wrapped = wrap_key(key)
        completed, result = with_key_operation(wrapped, timeout_deadline(timeout)) do |reservation|
          next false unless native_operation { concurrent_key?(wrapped) }

          current = native_operation { concurrent_get(wrapped) }
          next false unless values_equal?(current, expected)

          replaced = reservation.commit do
            native_operation { concurrent_store(wrapped, replacement) }
            changed!
          end
          replaced
        end
        completed && result
      end

      def update(key, timeout: nil)
        raise LocalJumpError, "no block given" unless block_given?

        wrapped = wrap_key(key)
        completed, result = with_key_operation(wrapped, timeout_deadline(timeout)) do |reservation|
          value = yield(native_operation { concurrent_get(wrapped) })
          stored = reservation.commit do
            native_operation { concurrent_store(wrapped, value) }
            changed!
          end
          value if stored
        end
        completed ? result : nil
      end

      # Yield presence and value under the key reservation.
      # MAP_KEEP and MAP_DELETE are control results. Other results replace the value.
      # Return whether a change committed.
      def modify(key) # rubocop:disable Naming/PredicateMethod
        raise LocalJumpError, "no block given" unless block_given?
        wrapped = wrap_key(key)
        _, result = with_key_operation(wrapped, nil) do |reservation|
          present, current = native_operation { [concurrent_key?(wrapped), concurrent_get(wrapped)] }
          value = yield(present, current)
          next false if MAP_KEEP.equal?(value)
          remove = MAP_DELETE.equal?(value)
          next false if remove && !present
          reservation.commit do
            native_operation do
              remove ? concurrent_delete(wrapped) : concurrent_store(wrapped, value)
            end
            changed!
          end
        end
        !!result
      end

      def upsert(key, initial_value, timeout: nil)
        raise LocalJumpError, "no block given" unless block_given?

        wrapped = wrap_key(key)
        completed, result = with_key_operation(wrapped, timeout_deadline(timeout)) do |reservation|
          present = native_operation { concurrent_key?(wrapped) }
          value = present ? yield(native_operation { concurrent_get(wrapped) }) : initial_value
          stored = reservation.commit do
            native_operation { concurrent_store(wrapped, value) }
            changed!
          end
          value if stored
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
        wrapped = wrap_key(key)
        _, result = with_key_operation(wrapped, nil) do |reservation|
          value = nil
          reservation.commit do
            value = native_operation { concurrent_delete(wrapped) }
            changed!
          end
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
        clear_key_operations do
          native_operation { concurrent_clear }
          changed!
        end
        self
      end

      def compute(key)
        wrapped = wrap_key(key)
        _, result = with_key_operation(wrapped, nil) do |reservation|
          value = yield(native_operation { concurrent_get(wrapped) })
          stored = reservation.commit do
            native_operation { concurrent_store(wrapped, value) }
            changed!
          end
          value if stored
        end
        result
      end

      def compute_if_absent(key)
        wrapped = wrap_key(key)
        _, result = with_key_operation(wrapped, nil) do |reservation|
          next native_operation { concurrent_get(wrapped) } if
            native_operation { concurrent_key?(wrapped) }

          value = yield
          stored = reservation.commit do
            native_operation { concurrent_store(wrapped, value) }
            changed!
          end
          value if stored
        end
        result
      end

      def compute_if_present(key)
        wrapped = wrap_key(key)
        _, result = with_key_operation(wrapped, nil) do |reservation|
          next unless native_operation { concurrent_key?(wrapped) }

          value = yield(native_operation { concurrent_get(wrapped) })
          stored = reservation.commit do
            native_operation { concurrent_store(wrapped, value) }
            changed!
          end
          value if stored
        end
        result
      end

      def delete_pair(key, value)
        return delete_pair_by_identity(key, value) if compare_values_by_identity?

        wrapped = wrap_key(key)
        _, result = with_key_operation(wrapped, nil) do |reservation|
          deleted = false
          reservation.commit do
            deleted = native_operation { concurrent_delete_pair(wrapped, value) }
            changed! if deleted
          end
          deleted
        end
        result
      end

      def get_and_set(key, value)
        wrapped = wrap_key(key)
        _, result = with_key_operation(wrapped, nil) do |reservation|
          previous = nil
          reservation.commit do
            previous = native_operation { concurrent_get_and_set(wrapped, value) }
            changed!
          end
          previous
        end
        result
      end

      def get_or_default(key, default) = concurrent_get_or_default(wrap_key(key), default)

      def merge_pair(key, value)
        wrapped = wrap_key(key)
        _, result = with_key_operation(wrapped, nil) do |reservation|
          present = native_operation { concurrent_key?(wrapped) }
          merged = present ? yield(native_operation { concurrent_get(wrapped) }) : value
          stored = reservation.commit do
            native_operation { concurrent_store(wrapped, merged) }
            changed!
          end
          merged if stored
        end
        result
      end

      def replace_if_exists(key, value)
        wrapped = wrap_key(key)
        _, result = with_key_operation(wrapped, nil) do |reservation|
          previous = nil
          reservation.commit do
            previous = native_operation { concurrent_replace_if_exists(wrapped, value) }
            changed!
          end
          previous
        end
        result
      end

      def replace_pair(key, expected, replacement)
        return replace_pair_by_identity(key, expected, replacement) if compare_values_by_identity?

        wrapped = wrap_key(key)
        _, result = with_key_operation(wrapped, nil) do |reservation|
          replaced = false
          reservation.commit do
            replaced = native_operation { concurrent_replace_pair(wrapped, expected, replacement) }
            changed! if replaced
          end
          replaced
        end
        result
      end

      private

      def wrap_key(key)
        return IdentityKey.new(key) if compare_keys_by_identity?
        key = String.instance_method(:-@).bind_call(key) if String === key && !key.frozen?
        key
      end

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
        wrapped = wrap_key(key)
        _, result = with_key_operation(wrapped, nil) do |reservation|
          next false unless native_operation { concurrent_key?(wrapped) } &&
            identical?(native_operation { concurrent_get(wrapped) }, expected)

          reservation.commit do
            native_operation { concurrent_delete(wrapped) }
            changed!
          end
        end
        result
      end

      def replace_pair_by_identity(key, expected, replacement)
        wrapped = wrap_key(key)
        _, result = with_key_operation(wrapped, nil) do |reservation|
          next false unless native_operation { concurrent_key?(wrapped) } &&
            identical?(native_operation { concurrent_get(wrapped) }, expected)

          reservation.commit do
            native_operation { concurrent_store(wrapped, replacement) }
            changed!
          end
        end
        result
      end

      def validate_boolean(value, name)
        return if identical?(value, true) || identical?(value, false)
        raise ArgumentError, "#{name} must be true or false"
      end

      def native_operation(&)
        entered = false
        @state_mutex.synchronize do
          reject_active_operation_reentry!
          Thread.handle_interrupt(INTERRUPT_MASK) do
            register_active_operation
            entered = true
          end
        end
        yield
      ensure
        Thread.handle_interrupt(INTERRUPT_MASK) { leave_operation } if entered
      end

      def leave_operation
        @state_mutex.synchronize { unregister_active_operation }
      end

      def changed! = @change_signal.broadcast

      def wait_for_value(key, expected, deadline, fallback, non_nil:)
        wrapped = wrap_key(key)
        while true
          generation = @change_signal.generation
          completed, current = with_key_operation(wrapped, deadline) do
            native_operation { concurrent_get(wrapped) }
          end
          return fallback&.call unless completed
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

      def reject_active_operation_reentry!
        return unless active_operation_owned_by?(Fiber.current)

        raise ThreadError, "deadlock; recursive map access during an operation"
      end

      def register_active_operation
        fiber = Fiber.current
        thread = Thread.current
        if @active_owners
          @active_owners[fiber] = thread
        elsif @active_owner_fiber
          owners = {}.compare_by_identity
          owners[@active_owner_fiber] = @active_owner_thread
          owners[fiber] = thread
          @active_owners = owners
          @active_owner_fiber = @active_owner_thread = nil
        else
          @active_owner_thread = thread
          @active_owner_fiber = fiber
        end
      end

      def unregister_active_operation
        if @active_owners
          removed = @active_owners.delete(Fiber.current)
          if @active_owners.one?
            @active_owner_fiber, @active_owner_thread = @active_owners.first
            @active_owners = nil
          end
          removed
        elsif identical?(@active_owner_fiber, Fiber.current)
          removed = @active_owner_thread
          @active_owner_fiber = @active_owner_thread = nil
          removed
        end
      end

      def active_operation_owned_by?(fiber)
        @active_owners ? @active_owners.key?(fiber) : identical?(@active_owner_fiber, fiber)
      end

      def values_equal?(left, right)
        compare_values_by_identity? ? identical?(left, right) : left == right
      end

      def identical?(left, right) = BASIC_OBJECT_EQUAL_METHOD.bind_call(left, right)

      private :concurrent_get, :concurrent_store, :concurrent_clear, :concurrent_compute,
        :concurrent_compute_if_absent, :concurrent_compute_if_present, :concurrent_delete,
        :concurrent_delete_pair, :concurrent_each_pair, :concurrent_get_and_set,
        :concurrent_get_or_default, :concurrent_key?, :concurrent_merge_pair,
        :concurrent_replace_if_exists, :concurrent_replace_pair, :concurrent_size
    end
  end
end
