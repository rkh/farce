# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class UnsharedVector
      def initialize(source = nil, compare_by_identity: false)
        validate_boolean(compare_by_identity, "compare_by_identity")
        raise TypeError, "source must be an Array" unless source.nil? || source.is_a?(Array)

        @values              = source ? Array.new(source) : []
        @compare_by_identity = compare_by_identity
        @mutex               = Mutex.new
        @signal              = Signal.new
        @updating            = false
      end

      def size = @mutex.synchronize { @values.size }

      def [](index)
        index = convert_index(index)
        @mutex.synchronize { @values[index] }
      end

      def []=(index, value)
        index     = convert_index(index)
        _, result = with_available(nil) { store_value(index, value) }
        result
      end

      def get(index, timeout: nil)
        index             = convert_index(index)
        completed, result = with_available(timeout_deadline(timeout)) { @values[index] }
        result if completed
      end

      def store(index, value, timeout: nil)
        index             = convert_index(index)
        completed, result = with_available(timeout_deadline(timeout)) { store_value(index, value) }
        completed ? result : false
      end

      def clear
        with_available(nil) do
          @values.clear
          changed!
        end
        self
      end

      def push(value, timeout: nil)
        completed, = with_available(timeout_deadline(timeout)) do
          @values.push(value)
          changed!
        end
        completed ? self : false
      end

      def pop(timeout: nil)
        completed, result = with_available(timeout_deadline(timeout)) do
          next if @values.empty?

          value = @values.pop
          changed!
          value
        end
        result if completed
      end

      def swap(index, replacement, timeout: nil)
        index             = convert_index(index)
        completed, result = with_available(timeout_deadline(timeout)) do
          index           = assignment_index(index)
          previous        = @values[index]
          @values[index]  = replacement
          changed!
          previous
        end
        result if completed
      end

      def store_if_absent(index, timeout: nil)
        raise LocalJumpError, "no block given" unless block_given?

        index                  = convert_index(index)
        completed, reservation = reserve(timeout_deadline(timeout)) do
          normalized           = assignment_index(index)
          current              = @values[normalized]
          if current.nil?
            @updating = true
            [:store, normalized]
          else
            [:existing, current]
          end
        end
        return unless completed
        return reservation.last if reservation.first == :existing

        _, normalized = reservation
        result        = yield
        @mutex.synchronize { @values[normalized] = result }
        result
      ensure
        finish_update if reservation&.first == :store
      end

      def compare_and_set(index, expected, replacement, timeout: nil)
        index                  = convert_index(index)
        completed, reservation = reserve(timeout_deadline(timeout)) do
          normalized = lookup_index(index)
          next unless normalized

          @updating = true
          [normalized, @values[normalized]]
        end
        return false unless completed && reservation

        normalized, current = reservation
        matches             = values_equal?(current, expected)
        @mutex.synchronize { @values[normalized] = replacement if matches }
        matches
      ensure
        finish_update if reservation
      end

      def upsert(index, initial, timeout: nil)
        raise LocalJumpError, "no block given" unless block_given?

        index                  = convert_index(index)
        completed, reservation = reserve(timeout_deadline(timeout)) do
          normalized           = assignment_index(index)
          current              = @values[normalized]
          if current.nil?
            @values[normalized] = initial
            changed!
            [:stored, initial]
          else
            @updating = true
            [:update, normalized, current]
          end
        end
        return unless completed
        return reservation.last if reservation.first == :stored

        _, normalized, current = reservation
        result                 = yield(current)
        @mutex.synchronize { @values[normalized] = result }
        result
      ensure
        finish_update if reservation&.first == :update
      end

      def update(index, timeout: nil)
        raise LocalJumpError, "no block given" unless block_given?

        index                  = convert_index(index)
        completed, reservation = reserve(timeout_deadline(timeout)) do
          normalized           = assignment_index(index)
          @updating            = true
          [normalized, @values[normalized]]
        end
        return unless completed

        normalized, current = reservation
        result              = yield(current)
        @mutex.synchronize { @values[normalized] = result }
        result
      ensure
        finish_update if reservation
      end

      def wait_until_changed(index, expected, timeout: nil)
        wait_for_value(convert_index(index), expected, timeout_deadline(timeout), non_nil: false)
      end

      def wait_until_non_nil(index, timeout: nil)
        wait_for_value(convert_index(index), nil, timeout_deadline(timeout), non_nil: true)
      end

      def compare_by_identity? = @compare_by_identity

      private

      def store_value(index, value)
        @values[assignment_index(index)] = value
        changed!
        value
      end

      def with_available(deadline)
        while true
          generation        = @signal.generation
          completed, result = @mutex.synchronize do
            @updating ? [false, nil] : [true, yield]
          end
          return [true, result] if completed
          return [false, nil] unless wait_for_signal(generation, deadline)
        end
      end

      def reserve(deadline)
        while true
          generation        = @signal.generation
          completed, result = @mutex.synchronize do
            @updating ? [false, nil] : [true, yield]
          end
          return [true, result] if completed
          return [false, nil] unless wait_for_signal(generation, deadline)
        end
      end

      def finish_update
        @mutex.synchronize { @updating = false }
        changed!
      end

      def changed! = @signal.broadcast

      def wait_for_value(index, expected, deadline, non_nil:)
        while true
          generation = @signal.generation
          current    = @mutex.synchronize { @values[index] }
          ready      = non_nil ? !current.nil? : !values_equal?(current, expected)
          return current if ready
          return unless wait_for_signal(generation, deadline)
        end
      end

      def wait_for_signal(generation, deadline)
        return @signal.wait(generation) unless deadline

        remaining = deadline - Clock.now
        return false unless remaining.positive?
        !@signal.wait(generation, timeout: remaining).nil?
      end

      def timeout_deadline(timeout)
        return if timeout.nil?

        timeout = Float(timeout)
        if !timeout.finite? || timeout.negative?
          raise ArgumentError, "timeout must be a finite, non-negative number or nil"
        end
        Clock.now + timeout
      end

      def lookup_index(index)
        index += @values.size if index.negative?
        index if index >= 0 && index < @values.size
      end

      def assignment_index(index)
        return index unless index.negative?

        normalized = @values.size + index
        return normalized unless normalized.negative?
        raise IndexError, "index #{index} too small for vector; minimum: -#{@values.size}"
      end

      def convert_index(index)
        return index if index.is_a?(Integer)

        raise TypeError, "no implicit conversion of #{index.class} into Integer" unless index.respond_to?(:to_int)
        converted = index.to_int
        return converted if converted.is_a?(Integer)
        raise TypeError, "can't convert #{index.class} to Integer"
      end

      def validate_boolean(value, name)
        return if value.equal?(true) || value.equal?(false)
        raise ArgumentError, "#{name} must be true or false"
      end

      def values_equal?(left, right)
        compare_by_identity? ? left.equal?(right) : left == right
      end
    end
  end
end
