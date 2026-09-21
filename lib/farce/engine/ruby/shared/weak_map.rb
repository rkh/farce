# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/ruby/shared/vault_weak_map"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class VaultWeakMapBase < Abstract::ConcurrentMap
      OWNER = Atom.new
      CLAIM_OWNERS = Object.new.freeze
      TIMED_OUT = Object.new.freeze
      private_constant :OWNER, :CLAIM_OWNERS, :TIMED_OUT

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
        @token                      = Object.new.freeze
        @vault                      = OWNER.store_if_absent { Vault.new }
        @freeze_state               = Flag.new(false)
        request(:create, {
          weak_keys:                weak_keys?,
          weak_values:              weak_values?,
          compare_keys_by_identity: compare_keys_by_identity?,
        }.freeze)
        initial_mapping&.each { self[it.first] = it.last }
        Object.instance_method(:freeze).bind_call(self)
      end

      def freeze
        @freeze_state.set
        self
      end

      def frozen? = @freeze_state.value

      def check_mutation = check_frozen!

      def prepare_mutation_key(key)
        check_frozen!
        canonical_key(key)
      end

      def [](key) = read(key, nil)[1]

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
        result = read(key, timeout_deadline(timeout))
        result.equal?(TIMED_OUT) ? fallback&.call : result[1]
      end

      def store(key, value, timeout: nil, &fallback)
        check_frozen!
        key = canonical_key(key)
        check_value(value, "value")
        result = await_response(deadline: timeout_deadline(timeout)) { request(:store, key, value, false) }
        result.equal?(TIMED_OUT) ? fallback&.call : value
      end

      def swap(key, replacement, timeout: nil, &fallback)
        check_frozen!
        key = canonical_key(key)
        check_value(replacement, "value")
        result = await_response(deadline: timeout_deadline(timeout)) { request(:store, key, replacement, true) }
        result.equal?(TIMED_OUT) ? fallback&.call : result[1]
      end

      def store_if_absent(key, timeout: nil, &update)
        raise LocalJumpError, "no block given" unless update

        claimed_update(key, timeout_deadline(timeout), claim: :absent) { update.call }
      end

      def compare_and_set(key, expected, replacement, timeout: nil)
        check_frozen!
        check_value(expected, "value")
        check_value(replacement, "value")
        matched = false
        claimed_update(key, timeout_deadline(timeout), claim: :present) do |current|
          next TIMED_OUT unless values_equal?(current, expected)

          check_frozen!
          matched = true
          replacement
        end
        matched
      end

      def update(key, timeout: nil, &update)
        raise LocalJumpError, "no block given" unless update

        claimed_update(key, timeout_deadline(timeout), claim: :always, &update)
      end

      def upsert(key, initial_value, timeout: nil, &update)
        raise LocalJumpError, "no block given" unless update
        check_value(initial_value, "value")

        claimed_update(key, timeout_deadline(timeout), claim: :present, initial: initial_value, &update)
      end

      # Yield presence and value under the entry claim.
      # MAP_KEEP and MAP_DELETE are control results. Other results replace the value.
      # Return whether a change committed.
      def modify(key)
        raise LocalJumpError, "no block given" unless block_given?
        check_frozen!
        key = canonical_key(key)
        ticket = Object.new.freeze
        sent = finished = false
        begin
          response = await_response(deadline: nil) do
            sent = true
            request(:claim, key, ticket, true)
          end
          present, current, signal = response[1], response[2], response[3]
          owners = claim_owners
          owners[signal] = Fiber.current
          value = yield(present, current)
          check_frozen!
          action = if MAP_KEEP.equal?(value)
                     :abort
                   elsif MAP_DELETE.equal?(value)
                     :delete
                   else
                     :store
                   end
          check_value(value, "value") if action == :store
          result = request(:finish, key, ticket, action, value)
          finished = true
          result.first != :stale && (action == :store || (action == :delete && present))
        ensure
          owners&.delete(signal)
          request(:finish, key, ticket, :abort) if sent && !finished
        end
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
      def shareable_keys?             = true
      def shareable_values?           = true
      def size                        = await_response(deadline: nil) { request(:size) }[1]
      def keys                        = entries_snapshot.map(&:first)

      def each(&block)
        return enum_for(__callee__) { size } unless block
        entries_snapshot.each { block.call(it) }
        self
      end
      alias each_pair each

      def each_live
        return enum_for(__method__) { size } unless block_given?
        token = request(:open_cursor)[1]
        begin
          while true
            result = await_response(deadline: nil) { request(:next_live, token) }
            break if result.first == :done
            yield [result[1], result[2]]
          end
        ensure
          request(:close_cursor, token)
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
        key = canonical_key(key)
        result = await_response(deadline: nil) { request(:delete, key) }
        result.first == :ok ? result[1] : nil
      end

      def getkey(key)
        key = canonical_key(key)
        result = await_response(deadline: nil) { request(:getkey, key) }
        result.first == :ok ? result[1] : nil
      end

      def clear
        check_frozen!
        request(:clear)
        self
      end

      private

      def check_frozen! = Internal::Freeze.check(self)

      def request(action, *) = @vault.weak_map(@token, action, *)

      def read(key, deadline)
        key = canonical_key(key)
        result = await_response(deadline:) { request(:read, key) }
        return TIMED_OUT if result.equal?(TIMED_OUT)
        return [false, nil] if result.first == :missing

        [result[1], result[2]]
      end

      def claimed_update(key, deadline, claim:, initial: TIMED_OUT)
        check_frozen!
        key = canonical_key(key)
        ticket = Object.new.freeze
        sent   = finished = false

        begin
          response = await_response(deadline:) do
            sent = true
            request(:claim, key, ticket, claim != :present || !initial.equal?(TIMED_OUT))
          end
          return if response.equal?(TIMED_OUT)
          return false if response.first == :missing

          present, current, signal = response[1], response[2], response[3]
          if claim == :absent && present
            request(:finish, key, ticket, :abort)
            finished = true
            return current
          end

          owners         = claim_owners
          owners[signal] = Fiber.current
          replacement    = present || initial.equal?(TIMED_OUT) ? yield(current) : initial
          check_frozen!

          if replacement.equal?(TIMED_OUT)
            request(:finish, key, ticket, :abort)
            finished = true
            return false
          end

          check_value(replacement, "value")
          result = request(:finish, key, ticket, :store, replacement)
          finished = true
          result.first == :stale ? nil : replacement
        ensure
          owners&.delete(signal)
          request(:finish, key, ticket, :abort) if sent && !finished
        end
      end

      def entries_snapshot
        result = await_response(deadline: nil) { request(:snapshot) }
        result[1]
      end

      def await_response(deadline:)
        checked_after_timeout = false
        loop do
          response = yield
          return response unless response.first == :busy

          signal, generation = response[1], response[2]
          reject_recursive_wait!(signal)
          timeout = remaining_timeout(deadline)
          if timeout&.zero?
            return TIMED_OUT if checked_after_timeout
            checked_after_timeout = true
            next
          end
          changed = signal.wait_until_changed(generation, timeout:) { TIMED_OUT }
          if changed.equal?(TIMED_OUT)
            return TIMED_OUT if checked_after_timeout
            checked_after_timeout = true
          end
        end
      end

      def wait_for_value(key, expected, deadline, fallback, non_nil:)
        key = canonical_key(key)
        check_value(expected, "value")
        checked_after_timeout = false
        loop do
          response = await_response(deadline:) { request(:wait_read, key) }
          return fallback&.call if response.equal?(TIMED_OUT)
          # Keep the canonical stored key alive, even when the lookup used a
          # different equal key. It arrives atomically with the entry's signal.
          key     = response[5] if response.first == :ok
          present = response.first == :ok && response[1]
          current = present ? response[2] : nil
          return current if non_nil ? !current.nil? : !values_equal?(current, expected)

          signal = response.first == :ok ? response[3] : response[1]
          generation = response.first == :ok ? response[4] : response[2]
          changed = signal.wait_until_changed(generation, timeout: remaining_timeout(deadline)) { TIMED_OUT }
          if changed.equal?(TIMED_OUT)
            return fallback&.call if checked_after_timeout
            checked_after_timeout = true
          end
        end
      end

      def claim_owners
        Storage.thread.store_if_absent(CLAIM_OWNERS) { {}.compare_by_identity }
      end

      def reject_recursive_wait!(signal)
        owner = claim_owners[signal]
        return unless owner
        raise ThreadError, "deadlock; recursive weak-map access during an update" if owner.equal?(Fiber.current)
        return if Fiber.respond_to?(:scheduler) && Fiber.scheduler

        raise ThreadError, "deadlock; weak-map update is owned by another unscheduled fiber"
      end

      def values_equal?(left, right)
        compare_values_by_identity? ? left.equal?(right) : left == right
      end

      def canonical_key(key)
        key = String.instance_method(:-@).bind_call(key) if String === key && !key.frozen? && !compare_keys_by_identity?
        check_value(key, "key")
      end

      def check_value(value, name)
        return value if Ractor.shareable?(value)
        raise Ractor::IsolationError, "#{name} must be Ractor-shareable"
      end

      def timeout_deadline(timeout)
        return if timeout.nil?

        timeout = Float(timeout)
        unless timeout.finite? && !timeout.negative?
          raise ArgumentError, "timeout must be a finite, non-negative number or nil"
        end
        Clock.now + timeout
      end

      def remaining_timeout(deadline)
        return unless deadline

        remaining = deadline - Clock.now
        remaining.positive? ? remaining : 0
      end

      def validate_boolean(value, name)
        return if value.equal?(true) || value.equal?(false)
        raise ArgumentError, "#{name} must be true or false"
      end
    end
    private_constant :VaultWeakMapBase

    class WeakKeyMap < VaultWeakMapBase
      def weak_keys?   = true
      def weak_values? = false
    end

    class WeakValueMap < VaultWeakMapBase
      def weak_keys?   = false
      def weak_values? = true
    end

    class WeakMap < VaultWeakMapBase
      def weak_keys?   = true
      def weak_values? = true
    end
  end
end
