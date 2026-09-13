# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Atom coordinates updates. The backend owns the weak slot and publishes
    # changes, including writes whose requesting thread was interrupted.
    class WeakAtomBase
      TIMED_OUT = Object.new.freeze
      private_constant :TIMED_OUT

      def initialize(value = nil, compare_by_identity: false)
        identity = BasicObject.instance_method(:equal?)
        unless identity.bind_call(compare_by_identity, true) || identity.bind_call(compare_by_identity, false)
          raise ArgumentError, "compare_by_identity must be a boolean"
        end
        validate_value(value)
        @compare_by_identity = compare_by_identity
        @lock                = Atom.new
        @changes             = Atom.new(0)
        initialize_storage(value)
      end

      def value                = read_value
      def compare_by_identity? = @compare_by_identity

      def value=(new_value)
        store(new_value)
      end

      def get(timeout: nil, &fallback)
        result = with_value(timeout) { read_value }
        result.equal?(TIMED_OUT) ? fallback&.call : result
      end

      def store(new_value, timeout: nil, &fallback)
        validate_value(new_value)
        result = with_value(timeout) do
          write_value(new_value)
          new_value
        end
        result.equal?(TIMED_OUT) ? fallback&.call : result
      end

      def swap(new_value, timeout: nil, &fallback)
        validate_value(new_value)
        result = with_value(timeout) do
          previous = read_value
          write_value(new_value)
          previous
        end
        result.equal?(TIMED_OUT) ? fallback&.call : result
      end

      def store_if_absent(timeout: nil)
        raise LocalJumpError, "no block given" unless block_given?
        result = with_value(timeout) do
          current = read_value
          next current unless current.nil?
          replacement = yield
          validate_value(replacement)
          write_value(replacement)
          replacement
        end
        result.equal?(TIMED_OUT) ? nil : result
      end

      def compare_and_set(expected, replacement, timeout: nil)
        validate_value(expected)
        validate_value(replacement)
        result = with_value(timeout) do
          next false unless values_equal?(read_value, expected)
          write_value(replacement)
          true
        end
        !result.equal?(TIMED_OUT) && result
      end

      def update(timeout: nil)
        raise LocalJumpError, "no block given" unless block_given?
        result = with_value(timeout) do
          replacement = yield(read_value)
          validate_value(replacement)
          write_value(replacement)
          replacement
        end
        result.equal?(TIMED_OUT) ? nil : result
      end

      def upsert(initial, timeout: nil)
        raise LocalJumpError, "no block given" unless block_given?
        validate_value(initial)
        result = with_value(timeout) do
          current = read_value
          replacement = current.nil? ? initial : yield(current)
          validate_value(replacement)
          write_value(replacement)
          replacement
        end
        result.equal?(TIMED_OUT) ? nil : result
      end

      def wait_until_changed(expected, timeout: nil, &fallback)
        validate_value(expected)
        wait_for_value(expected, timeout, fallback, non_nil: false)
      end

      def wait_until_non_nil(timeout: nil, &fallback)
        wait_for_value(nil, timeout, fallback, non_nil: true)
      end

      private

      def validate_value(_value); end

      def with_value(timeout)
        deadline = timeout_deadline(timeout)
        result = TIMED_OUT
        @lock.update(timeout: remaining_timeout(deadline)) do
          result = yield
          nil
        end
        result
      end

      def wait_for_value(expected, timeout, fallback, non_nil:)
        deadline = timeout_deadline(timeout)
        loop do
          generation = @changes.value
          current    = read_value
          return current if non_nil ? !current.nil? : !values_equal?(current, expected)
          # Detect recursive waits without waiting for another owner's update.
          @lock.get(timeout: 0)
          return fallback&.call if remaining_timeout(deadline)&.zero?
          @changes.wait_until_changed(generation, timeout: remaining_timeout(deadline))
        end
      end

      def values_equal?(left, right)
        return left == right unless compare_by_identity?
        BasicObject.instance_method(:equal?).bind_call(left, right)
      end

      def timeout_deadline(timeout)
        return if timeout.nil?
        timeout = Float(timeout)
        raise ArgumentError, "timeout must be finite and non-negative" unless timeout.finite? && !timeout.negative?
        Clock.now + timeout
      end

      def remaining_timeout(deadline)
        return unless deadline
        [deadline - Clock.now, 0].max
      end
    end
    private_constant :WeakAtomBase
  end
end
