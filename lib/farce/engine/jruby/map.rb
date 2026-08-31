# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Map
      BASIC_OBJECT_EQUAL_METHOD = BasicObject.instance_method(:equal?)
      INTERRUPT_MASK = { Exception => :never }.freeze
      private_constant :BASIC_OBJECT_EQUAL_METHOD, :INTERRUPT_MASK

      class Key
        attr_reader :value

        def initialize(value) = @value = value
        def hash = value.hash
        def eql?(other) = other.is_a?(Key) && value.eql?(other.value)

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
        @map           = java.util.concurrent.ConcurrentHashMap.new
        # Native operations may overlap; block updates reserve exclusive access.
        @state_mutex   = Mutex.new
        @state_signal  = Signal.new
        @change_signal = Signal.new
        @active_owner_fiber  = nil
        @active_owner_thread = nil
        @active_owners = nil
        @exclusive     = false
        @exclusive_fiber  = nil
        @exclusive_thread = nil
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
        stored = @map.get(wrap_key(key))
        return stored.value if stored
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
          previous = concurrent_swap(wrap_key(key), replacement)
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
        _, result = with_operation(nil) do
          @map.clear
          changed!
          self
        end
        result
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

        @map.each_pair do |stored, _value|
          return stored.value if stored.eql?(wrapped)
        end
        nil
      end

      private

      def wrap_key(key) = compare_keys_by_identity? ? IdentityKey.new(key) : Key.new(key)

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

      def validate_boolean(value, name)
        return if identical?(value, true) || identical?(value, false)
        raise ArgumentError, "#{name} must be true or false"
      end

      def with_operation(deadline)
        entered = false
        available = enter_operation(deadline) { entered = true }
        return [false, nil] unless available
        [true, yield]
      ensure
        Thread.handle_interrupt(INTERRUPT_MASK) { leave_operation } if entered
      end

      def enter_operation(deadline)
        while true # rubocop:disable Style/InfiniteLoop
          generation = @state_signal.generation
          entered = @state_mutex.synchronize do
            if @exclusive
              reject_exclusive_wait!
              next false
            end
            reject_active_operation_reentry!
            yield
            register_active_operation
            true
          end
          return true if entered
          return false unless wait_for_signal(@state_signal, generation, deadline)
        end
      end

      def leave_operation
        notify = @state_mutex.synchronize do
          removed = unregister_active_operation
          removed && !active_operation?
        end
        @state_signal.broadcast if notify
      end

      def with_exclusive_update(deadline)
        entered = false
        available = enter_exclusive_update(deadline) { entered = true }
        return [false, nil] unless available
        [true, yield]
      ensure
        Thread.handle_interrupt(INTERRUPT_MASK) { leave_exclusive_update } if entered
      end

      def enter_exclusive_update(deadline)
        while true # rubocop:disable Style/InfiniteLoop
          generation = @state_signal.generation
          entered = @state_mutex.synchronize do
            if @exclusive
              reject_exclusive_wait!
              next false
            end
            if active_operation?
              reject_active_wait!
              next false
            end
            yield
            @exclusive_fiber  = Fiber.current
            @exclusive_thread = Thread.current
            @exclusive        = true
            true
          end
          return true if entered
          return false unless wait_for_signal(@state_signal, generation, deadline)
        end
      end

      def leave_exclusive_update
        released = @state_mutex.synchronize do
          next false unless identical?(@exclusive_fiber, Fiber.current)

          was_exclusive = @exclusive
          @exclusive = false
          @exclusive_fiber = @exclusive_thread = nil
          was_exclusive
        end
        @state_signal.broadcast if released
      end

      def changed! = @change_signal.broadcast

      def wait_for_value(key, expected, deadline, fallback, non_nil:)
        while true # rubocop:disable Style/InfiniteLoop
          generation = @change_signal.generation
          current = self[key]
          ready = non_nil ? !current.nil? : !values_equal?(current, expected)
          return current if ready
          @state_mutex.synchronize { reject_exclusive_wait! if @exclusive }
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

      def reject_exclusive_wait!
        raise ThreadError, "deadlock; recursive map access during an update" if
          identical?(@exclusive_fiber, Fiber.current)

        scheduler = Fiber.scheduler if Fiber.respond_to?(:scheduler)
        return unless identical?(@exclusive_thread, Thread.current) && !scheduler

        raise ThreadError, "deadlock; map update is owned by another unscheduled fiber"
      end

      def reject_active_operation_reentry!
        return unless active_operation_owned_by?(Fiber.current)

        raise ThreadError, "deadlock; recursive map access during an operation"
      end

      def reject_active_wait!
        reject_active_operation_reentry!

        scheduler = Fiber.scheduler if Fiber.respond_to?(:scheduler)
        return if scheduler
        return unless active_operation_on_thread?(Thread.current)

        raise ThreadError, "deadlock; map operation is owned by another unscheduled fiber"
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

      def active_operation? = !@active_owner_fiber.nil? || !@active_owners.nil?

      def active_operation_owned_by?(fiber)
        @active_owners ? @active_owners.key?(fiber) : identical?(@active_owner_fiber, fiber)
      end

      def active_operation_on_thread?(thread)
        return identical?(@active_owner_thread, thread) unless @active_owners

        @active_owners.each_value.any? { |owner| identical?(owner, thread) }
      end

      def values_equal?(left, right)
        compare_values_by_identity? ? identical?(left, right) : left == right
      end

      def identical?(left, right) = BASIC_OBJECT_EQUAL_METHOD.bind_call(left, right)
    end
  end
end
