# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/shared/weak_map/lock"
require "farce/engine/shared/weak_map/cell"
require "farce/engine/shared/weak_map/index"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class UnsharedMapBase < Abstract::ConcurrentMap
      def initialize(
        initial_mapping = nil,
        compare_by_identity: false,
        compare_keys_by_identity: compare_by_identity,
        compare_values_by_identity: compare_by_identity
      )
        validate_boolean(compare_by_identity,        "compare_by_identity")
        validate_boolean(compare_keys_by_identity,   "compare_keys_by_identity")
        validate_boolean(compare_values_by_identity, "compare_values_by_identity")
        raise TypeError, "initial mapping must be a Hash" unless initial_mapping.nil? || initial_mapping.is_a?(Hash)

        super()

        @compare_keys_by_identity   = compare_keys_by_identity
        @compare_values_by_identity = compare_values_by_identity
        @cell_class                 = weak_values? ? UnsharedWeakValueMapCell : UnsharedWeakMapCell

        index_class = if weak_keys?
                        compare_keys_by_identity? ? UnsharedWeakIdentityMapIndex : UnsharedWeakKeyMapIndex
                      else
                        compare_keys_by_identity? ? UnsharedStrongIdentityMapIndex : UnsharedStrongKeyMapIndex
                      end
        @index = index_class.new
        initial_mapping&.each { self[it.first] = it.last }
      end

      def [](key) = read_unreserved(key)[1]

      def check_mutation = check_frozen!

      def prepare_mutation_key(key)
        check_frozen!
        canonical_key(key)
      end

      def []=(key, value)
        store(key, value)
      end

      def fetch(*arguments)
        unless arguments.length.between?(1, 2)
          raise ArgumentError, "wrong number of arguments (given #{arguments.length}, expected 1..2)"
        end

        key, default  = arguments
        default_given = arguments.length == 2
        warn "block supersedes default value argument", uplevel: 1 if block_given? && default_given
        present, value = read(key, nil)
        return value if present
        return yield(key) if block_given?
        return default if default_given

        raise KeyError.new("key not found: #{key.inspect}", receiver: self, key: key)
      end

      def get(key, timeout: nil, &fallback)
        deadline                   = timeout_deadline(timeout)
        _present, value, timed_out = read(key, deadline)
        timed_out ? fallback&.call : value
      end

      def store(key, value, timeout: nil, &fallback)
        check_frozen!
        deadline          = timeout_deadline(timeout)
        completed, result = with_entry(key, deadline, create: true, mutating: true) do |_present, _current, entry|
          value if entry.store(value)
        end
        completed ? result : fallback&.call
      end

      def swap(key, replacement, timeout: nil, &fallback)
        check_frozen!
        deadline          = timeout_deadline(timeout)
        completed, result = with_entry(key, deadline, create: true, mutating: true) do |present, current, entry|
          stored = entry.store(replacement)
          current if stored && present
        end
        completed ? result : fallback&.call
      end

      def store_if_absent(key, timeout: nil)
        raise LocalJumpError, "no block given" unless block_given?
        check_frozen!

        deadline          = timeout_deadline(timeout)
        completed, result = with_entry(key, deadline, create: true, mutating: true) do |present, current, entry|
          next current if present
          value = yield
          check_frozen!
          value if entry.store(value)
        end
        completed ? result : nil
      end

      def compare_and_set(key, expected, replacement, timeout: nil)
        check_frozen!
        deadline          = timeout_deadline(timeout)
        completed, result = with_entry(key, deadline, create: false, mutating: true) do |present, current, entry|
          next false unless present && values_equal?(current, expected)

          check_frozen!
          entry.store(replacement)
        end
        completed && result
      end

      def update(key, timeout: nil)
        raise LocalJumpError, "no block given" unless block_given?
        check_frozen!

        deadline          = timeout_deadline(timeout)
        completed, result = with_entry(key, deadline, create: true, mutating: true) do |_present, current, entry|
          value = yield(current)
          check_frozen!
          value if entry.store(value)
        end
        completed ? result : nil
      end

      def upsert(key, initial_value, timeout: nil)
        raise LocalJumpError, "no block given" unless block_given?
        check_frozen!

        deadline          = timeout_deadline(timeout)
        completed, result = with_entry(key, deadline, create: true, mutating: true) do |present, current, entry|
          value = present ? yield(current) : initial_value
          check_frozen!
          value if entry.store(value)
        end
        completed ? result : nil
      end

      # Yield presence and value under the entry reservation.
      # MAP_KEEP and MAP_DELETE are control results. Other results replace the value.
      # Return whether a change committed.
      def modify(key) # rubocop:disable Naming/PredicateMethod
        raise LocalJumpError, "no block given" unless block_given?
        check_frozen!
        _, result = with_entry(key, nil, create: true, mutating: true) do |present, current, entry, index|
          value = yield(present, current)
          check_frozen!
          if MAP_KEEP.equal?(value)
            false
          elsif MAP_DELETE.equal?(value)
            next false unless present
            index.remove(key, entry)
            entry.retire
          else
            entry.store(value)
          end
        end
        !!result
      end

      def wait_until_changed(key, expected, timeout: nil, &fallback)
        wait_for_value(key, expected, timeout_deadline(timeout), fallback, non_nil: false)
      end

      def wait_until_non_nil(key, timeout: nil, &fallback)
        wait_for_value(key, nil, timeout_deadline(timeout), fallback, non_nil: true)
      end

      def key?(key)                   = read(key, nil).first
      def compare_keys_by_identity?   = @compare_keys_by_identity
      def compare_values_by_identity? = @compare_values_by_identity
      def size                        = entries_snapshot.size
      def keys                        = entries_snapshot.map(&:first)

      def each(&block)
        return enum_for(__callee__) { size } unless block
        entries_snapshot.each { block.call(it) }
        self
      end
      alias each_pair each

      def each_live
        return enum_for(__method__) { size } unless block_given?
        cursor = @index.live_cursor
        begin
          while true
            begin
              entry = @index.next_live(cursor)
            rescue StopIteration
              break
            end
            next unless entry.reserve(nil) == :acquired
            pair = begin
              state, present, value = entry.state
              alive, key            = entry.lookup_key if state == :ok && present
              [key, value] if alive
            ensure
              entry.release
            end
            yield pair if pair
          end
        ensure
          @index.close_cursor(cursor)
        end
        self
      end

      def each_key(&block)
        return enum_for(__callee__) { size } unless block
        entries_snapshot.each { block.call(it.first) }
        self
      end

      def each_value(&block)
        return enum_for(__callee__) { size } unless block
        entries_snapshot.each { block.call(it.last) }
        self
      end

      def delete(key)
        check_frozen!
        completed, result = with_entry(key, nil, create: false, mutating: true) do |present, current, entry, index|
          next nil unless present
          index.remove(key, entry)
          entry.retire
          current if present
        end
        result if completed
      end

      def getkey(key)
        @index.sweep_one
        entry, created = @index.resolve(key)
        return if !entry || created == :timed_out

        alive, stored_key = entry.lookup_key
        stored_key if alive
      end

      def clear
        check_frozen!
        @index.clear
        self
      end

      private

      def check_frozen! = Internal::Freeze.check(self)

      def canonical_key(key)
        return key unless String === key && !key.frozen? && !compare_keys_by_identity?

        String.instance_method(:-@).bind_call(key)
      end

      def read_unreserved(key)
        @index.sweep_one
        loop do
          entry, = @index.resolve(key)
          return [false, nil] unless entry

          state, present, value = entry.state
          return [present, value] if state == :ok

          @index.remove(key, entry)
          entry.retire
        end
      end

      def read(key, deadline)
        completed, result = with_entry(key, deadline, create: false) { |present, value| [present, value] }
        completed ? [*result, false] : [false, nil, result == :timed_out]
      end

      def with_entry(key, deadline, create:, mutating: false)
        key = canonical_key(key)
        @index.sweep_one
        while true
          entry, created = @index.resolve(key, deadline:, create:) do |key_reference|
            cell         = @cell_class.new(key_reference)
            cell.reserve(nil)
            cell
          end
          return [false, :timed_out] if created == :timed_out
          unless entry
            check_frozen! if mutating
            return [true, yield(false, nil, nil, @index)]
          end

          unless created
            status = entry.reserve(deadline)
            return [false, :timed_out] if status == :timed_out
            next if status == :retired
          end

          retry_entry = false
          begin
            state, present, current = entry.state
            if state == :ok
              check_frozen! if mutating
              return [true, yield(present, current, entry, @index)]
            end
            retry_entry = true
          ensure
            begin
              if created && !entry.present?
                @index.remove(key, entry)
                entry.retire
              end
            ensure
              entry.release
            end
          end
          if retry_entry
            @index.remove(key, entry)
            entry.retire
          end
        end
      end

      def entries_snapshot
        entries  = @index.snapshot
        pairs    = entries.filter_map do |entry|
          status = entry.reserve(nil)
          next unless status == :acquired

          begin
            state, present, value = entry.state
            next unless state == :ok && present
            alive, key = entry.lookup_key
            [key, value] if alive
          ensure
            entry.release
          end
        end
        @index.sweep(entries)
        pairs
      end

      def wait_for_value(key, expected, deadline, fallback, non_nil:)
        key = String.instance_method(:-@).bind_call(key) if String === key && !key.frozen? && !compare_keys_by_identity?
        while true
          @index.sweep_one
          observed         = @index.change_signal.generation
          entry, timed_out = @index.resolve(key, deadline:)
          return fallback&.call if timed_out == :timed_out

          unless entry
            return nil unless values_equal?(nil, expected)
            return fallback&.call unless signal_changed?(@index.change_signal, observed, deadline)
            next
          end

          changed = entry.change_generation
          status  = entry.reserve(deadline)
          return fallback&.call if status == :timed_out
          next if status == :retired

          begin
            alive, stored_key = entry.lookup_key
            state, present, current = entry.state
          ensure
            entry.release
          end
          next if !alive || state == :retired || state == :dead
          # Retain the canonical key across the wait, including for an equal
          # lookup object. Otherwise GC could orphan the entry's change signal.
          key     = stored_key
          current = nil unless present
          return current if non_nil ? !current.nil? : !values_equal?(current, expected)
          return fallback&.call unless entry.wait_for_change?(changed, deadline)
        end
      end

      def signal_changed?(signal, observed, deadline)
        timeout = deadline - Clock.now if deadline
        return false if timeout && !timeout.positive?

        timed_out = Object.new
        result    = signal.wait(observed, timeout:) { timed_out }
        !timed_out.equal?(result)
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
        return BasicObject.instance_method(:equal?).bind_call(left, right) if compare_values_by_identity?
        left == right
      end

      def validate_boolean(value, name)
        equal = BasicObject.instance_method(:equal?)
        return if equal.bind_call(value, true) || equal.bind_call(value, false)
        raise ArgumentError, "#{name} must be true or false"
      end
    end
    private_constant :UnsharedMapBase

    class UnsharedMap < UnsharedMapBase
    end

    class UnsharedWeakKeyMap < UnsharedMapBase
      def weak_keys? = true
    end

    class UnsharedWeakValueMap < UnsharedMapBase
      def weak_values? = true
    end

    class UnsharedWeakMap < UnsharedMapBase
      def weak_keys? = true
      def weak_values? = true
    end

    unless RUBY_ENGINE == "ruby"
      WeakKeyMap   = UnsharedWeakKeyMap
      WeakValueMap = UnsharedWeakValueMap
      WeakMap      = UnsharedWeakMap
    end
  end
end
