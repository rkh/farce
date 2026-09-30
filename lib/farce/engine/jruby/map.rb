# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/shared/map_key_coordination"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Map
      include MapKeyCoordination
      include TransactionMapBackend

      BASIC_OBJECT_EQUAL_METHOD = BasicObject.instance_method(:equal?)
      private_constant :BASIC_OBJECT_EQUAL_METHOD

      class Key
        attr_accessor :mutation_owner
        attr_reader :value

        def initialize(value) = @value = value

        def hash
          result = value.hash
          owner = mutation_owner
          Internal::Freeze.check(owner) if owner
          result
        end

        def eql?(other)
          result = other.is_a?(Key) && value.eql?(other.value)
          owner = mutation_owner || (other.mutation_owner if other.is_a?(Key))
          Internal::Freeze.check(owner) if owner
          result
        end

        alias == eql?
      end
      private_constant :Key

      # The Java bridge converts objects such as Ruby strings unless they are boxed.
      class Value
        attr_reader :value

        def initialize(value) = @value = value
      end
      private_constant :Value

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

        @compare_keys_by_identity   = compare_keys_by_identity
        @compare_values_by_identity = compare_values_by_identity
        @freeze_state = Flag.new(false)
        @map           = java.util.concurrent.ConcurrentHashMap.new
        # Native operations may overlap. Block updates reserve one logical key.
        @state_mutex   = Mutex.new
        @change_signal = Signal.new
        @active_owner_fiber  = nil
        @active_owner_thread = nil
        @active_owners = nil
        initialize_key_coordination
        initial_mapping&.each do |key, value|
          check_frozen!
          wrapped = wrap_key(key)
          with_mutation_callback_guard(wrapped) { concurrent_store(wrapped, value) }
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

      def check_mutation = check_frozen!

      def prepare_mutation_key(key)
        check_frozen!
        normalize_external_key(key)
      end

      def [](key) = concurrent_get(wrap_key(key))

      def fetch(*arguments)
        unless arguments.length.between?(1, 2)
          raise ArgumentError, "wrong number of arguments (given #{arguments.length}, expected 1..2)"
        end

        key, default = arguments
        default_given = arguments.length == 2
        warn "block supersedes default value argument", uplevel: 1 if block_given? && default_given
        stored = @map.get(wrap_key(key))
        return stored.value if stored
        return yield(key) if block_given?
        return default if default_given

        raise KeyError.new("key not found: #{key.inspect}", receiver: self, key: key)
      end

      def []=(key, value)
        check_frozen!
        wrapped = wrap_key(key)
        _, result = with_mutating_key_operation(wrapped, nil) do |reservation|
          commit_mutation(reservation) do
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
        check_frozen!
        wrapped = wrap_key(key)
        completed, result = with_mutating_key_operation(wrapped, timeout_deadline(timeout)) do |reservation|
          commit_mutation(reservation) do
            native_operation { concurrent_store(wrapped, value) }
            changed!
          end
          value
        end
        completed ? result : fallback&.call
      end

      def swap(key, replacement, timeout: nil, &fallback)
        check_frozen!
        wrapped = wrap_key(key)
        completed, result = with_mutating_key_operation(wrapped, timeout_deadline(timeout)) do |reservation|
          previous = nil
          commit_mutation(reservation) do
            previous = native_operation { concurrent_swap(wrapped, replacement) }
            changed!
          end
          previous
        end
        completed ? result : fallback&.call
      end

      def store_if_absent(key, timeout: nil)
        raise LocalJumpError, "no block given" unless block_given?
        check_frozen!

        wrapped = wrap_key(key)
        completed, result = with_mutating_key_operation(wrapped, timeout_deadline(timeout)) do |reservation|
          if native_operation { concurrent_key?(wrapped) }
            native_operation { concurrent_get(wrapped) }
          else
            value = yield
            stored = commit_mutation(reservation) do
              native_operation { concurrent_store(wrapped, value) }
              changed!
            end
            value if stored
          end
        end
        completed ? result : nil
      end

      def compare_and_set(key, expected, replacement, timeout: nil)
        check_frozen!
        wrapped = wrap_key(key)
        completed, result = with_mutating_key_operation(wrapped, timeout_deadline(timeout)) do |reservation|
          next false unless native_operation { concurrent_key?(wrapped) }

          current = native_operation { concurrent_get(wrapped) }
          next false unless values_equal?(current, expected)

          replaced = commit_mutation(reservation) do
            native_operation { concurrent_store(wrapped, replacement) }
            changed!
          end
          replaced
        end
        completed && result
      end

      def update(key, timeout: nil)
        raise LocalJumpError, "no block given" unless block_given?
        check_frozen!

        wrapped = wrap_key(key)
        completed, result = with_mutating_key_operation(wrapped, timeout_deadline(timeout)) do |reservation|
          value = yield(native_operation { concurrent_get(wrapped) })
          stored = commit_mutation(reservation) do
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
        check_frozen!
        wrapped = wrap_key(key)
        _, result = with_mutating_key_operation(wrapped, nil) do |reservation|
          present, current = native_operation { [concurrent_key?(wrapped), concurrent_get(wrapped)] }
          value = yield(present, current)
          next false if MAP_KEEP.equal?(value)
          remove = MAP_DELETE.equal?(value)
          next false if remove && !present
          commit_mutation(reservation) do
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
        check_frozen!

        wrapped = wrap_key(key)
        completed, result = with_mutating_key_operation(wrapped, timeout_deadline(timeout)) do |reservation|
          present = native_operation { concurrent_key?(wrapped) }
          value = present ? yield(native_operation { concurrent_get(wrapped) }) : initial_value
          stored = commit_mutation(reservation) do
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
      def size = @map.size
      def compare_keys_by_identity? = @compare_keys_by_identity
      def compare_values_by_identity? = @compare_values_by_identity

      def keys = entries_snapshot.map(&:first)

      def each(&block)
        return enum_for(__callee__) { size } unless block

        entries_snapshot.each { |pair| block.call(pair) }
        self
      end
      alias each_pair each

      def each_live
        return enum_for(__method__) { size } unless block_given?
        iterator = @map.entry_set.iterator
        while iterator.has_next
          entry = iterator.next
          yield [entry.key.value, entry.value.value]
        end
        self
      end

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

      def clear
        check_frozen!
        clear_key_operations do
          native_operation { @map.clear }
          changed!
        end
        self
      end

      def delete(key)
        check_frozen!
        wrapped = wrap_key(key)
        _, result = with_mutating_key_operation(wrapped, nil) do |reservation|
          value = nil
          commit_mutation(reservation) do
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

        @map.each_pair do |stored, _value|
          return stored.value if stored.eql?(wrapped)
        end
        nil
      end

      private

      def check_frozen! = Internal::Freeze.check(self)

      def commit_mutation(reservation, &)
        check_frozen!
        reservation.commit(&)
      end

      def with_mutating_key_operation(key, deadline, &)
        with_key_operation(key, deadline) do |reservation|
          with_mutation_callback_guard(key) do
            check_frozen!
            yield reservation
          end
        end
      end

      def with_mutation_callback_guard(key)
        return yield unless key.is_a?(Key)

        key.mutation_owner = self
        yield
      ensure
        key.mutation_owner = nil if key.is_a?(Key)
      end

      def wrap_key(key)
        return IdentityKey.new(key) if compare_keys_by_identity?
        key = String.instance_method(:-@).bind_call(key) if String === key && !key.frozen?
        Key.new(key)
      end

      def entries_snapshot
        entries = []
        @map.each_pair { |key, value| entries << [key.value, value.value] }
        entries
      end

      def concurrent_get(key)
        stored = @map.get(key)
        stored&.value
      end

      def concurrent_store(key, value)
        @map.put(key, Value.new(value))
        value
      end

      def concurrent_swap(key, value)
        previous = @map.put(key, Value.new(value))
        previous&.value
      end

      def concurrent_key?(key) = @map.contains_key(key)

      def concurrent_delete(key)
        previous = @map.remove(key)
        previous&.value
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

      def validate_boolean(value, name)
        return if identical?(value, true) || identical?(value, false)
        raise ArgumentError, "#{name} must be true or false"
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
    end
  end
end
