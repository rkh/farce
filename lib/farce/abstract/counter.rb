# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract Common numeric interface and atomic operations for counters.
    # @note This is a module rather than a class so {Farce::Counter} can inherit
    #   directly from the native counter and avoid delegation overhead.
    module Counter
      include Internal::Copyable

      def self.included(base)
        Internal.prepare_mutable_numeric(base)
        super
      end

      # Numeric's default copying returns self, which is unsuitable for mutable counters.
      define_method(:dup,   Kernel.instance_method(:dup))
      define_method(:clone, Kernel.instance_method(:clone))

      include Value
      include Internal::ValueSerialization

      # Wait until the current value differs from the expected value.
      # @param expected [Integer] the value to wait to change from
      # @param timeout [Numeric, nil] the total seconds available
      # @yield called when the timeout expires
      # @return [Integer, BasicObject, nil] the changed value or timeout fallback
      def wait_until_changed(expected, timeout: nil)
        signal = change_signal
        Internal.with_timeout(timeout) do |_, deadline|
          observed = signal.generation
          current = value
          return current unless expected == current
          break unless signal.wait(observed, timeout: Internal.remaining_timeout(deadline))
        end
        yield if block_given?
      end

      # Wait until a block condition matches the current value.
      # One timeout budget covers all checks and waits. The block is not interrupted.
      # @yieldparam value [Integer] the current value
      # @yieldreturn [Boolean] whether the value matches
      # @param timeout [Numeric, nil] the total seconds available
      # @return [Integer, nil] the matching value, or nil on timeout
      # @raise [LocalJumpError] if no block is given
      def wait_until(timeout: nil, &) = Internal.wait_until(self, timeout:, &)

      # Wait while the block returns a truthy value.
      # @yieldparam value [Integer] the current value
      # @yieldreturn [BasicObject] a truthy value to keep waiting, or nil or false to stop
      # @param timeout [Numeric, nil] the total seconds available
      # @return [Integer, nil] the value when the condition becomes false, or nil on timeout
      # @raise [LocalJumpError] if no block is given
      def wait_while(timeout: nil)
        raise LocalJumpError, "no block given" unless block_given?
        wait_until(timeout:) { |value| !yield(value) }
      end

      # Wait while `object === value` is true.
      # @param object [#===] the pattern to stop matching
      # @param timeout [Numeric, nil] the total seconds available
      # @return [Integer, nil] the first nonmatching value, or nil on timeout
      def wait_while_match(object, timeout: nil)
        wait_while(timeout:) { |value| object === value } # rubocop:disable Style/CaseEquality
      end

      # (see #wait_until_changed)
      def wait_while_value(...) = wait_until_changed(...)

      # Wait until `object == value` is true.
      # Counters compare integer values by equality.
      # @param object [BasicObject] the value to compare with the current value
      # @param timeout [Numeric, nil] the total seconds available
      # @return [Integer, nil] the matching value, or nil on timeout
      def wait_until_value(object, timeout: nil)
        wait_until(timeout:) { |value| object == value }
      end

      # Wait until `object === value` is true.
      # @param object [#===] the pattern to match
      # @param timeout [Numeric, nil] the total seconds available
      # @return [Integer, nil] the matching value, or nil on timeout
      def wait_until_match(object, timeout: nil)
        wait_until(timeout:) { |value| object === value } # rubocop:disable Style/CaseEquality
      end

      # Wait until the value is strictly below the limit.
      # @param limit [Numeric, String, #to_int] the upper bound, converted to an Integer
      # @param timeout [Numeric, nil] the total seconds available
      # @return [Integer, nil] the matching value, or nil on timeout
      def wait_until_below(limit, timeout: nil)
        limit = Integer(limit)
        wait_until(timeout:) { |value| value < limit }
      end

      # Wait until the value is strictly above the floor.
      # @param floor [Numeric, String, #to_int] the lower bound, converted to an Integer
      # @param timeout [Numeric, nil] the total seconds available
      # @return [Integer, nil] the matching value, or nil on timeout
      def wait_until_above(floor, timeout: nil)
        floor = Integer(floor)
        wait_until(timeout:) { |value| value > floor }
      end

      # Wait while the value is strictly above the limit.
      # @param limit [Numeric, String, #to_int] the upper bound, converted to an Integer
      # @param timeout [Numeric, nil] the total seconds available
      # @return [Integer, nil] the first value at or below the limit, or nil on timeout
      def wait_while_above(limit, timeout: nil)
        limit = Integer(limit)
        wait_until(timeout:) { |value| value <= limit }
      end

      # Wait while the value is strictly below the floor.
      # @param floor [Numeric, String, #to_int] the lower bound, converted to an Integer
      # @param timeout [Numeric, nil] the total seconds available
      # @return [Integer, nil] the first value at or above the floor, or nil on timeout
      def wait_while_below(floor, timeout: nil)
        floor = Integer(floor)
        wait_until(timeout:) { |value| value >= floor }
      end

      # Reset the counter to its initial value.
      # @return [self] Returns self for chaining.
      def reset
        self.value = initial
        self
      end

      # Increment the counter by one if its current value is below the limit.
      # The check and increment happen atomically.
      # @param [Numeric, String, #to_int] limit The upper bound, converted to an Integer.
      # @return [Boolean] true if the counter changed, otherwise false.
      def increment_if_below(limit) # rubocop:disable Naming/PredicateMethod
        limit   = Integer(limit)
        current = value

        Internal::Freeze.check(self)

        while current < limit
          return true if compare_and_set(current, current + 1)
          current = value
        end

        false
      end

      # Decrement the counter by one if its current value is above the floor.
      # The check and decrement happen atomically.
      # @param [Numeric, String, #to_int] floor The lower bound, converted to an Integer.
      # @return [Boolean] true if the counter changed, otherwise false.
      def decrement_if_above(floor) # rubocop:disable Naming/PredicateMethod
        floor   = Integer(floor)
        current = value

        Internal::Freeze.check(self)

        while current > floor
          return true if compare_and_set(current, current - 1)
          current = value
        end

        false
      end

      # @overload add(by = 1)
      #   (see #increment)
      def add(...) = increment(...)

      methods  = Integer.public_instance_methods - Object.public_instance_methods - [:singleton_method_added]
      methods += %i[+ - / * ** <=> coerce rationalize to_i to_int to_f to_c to_r to_s]
      methods.uniq!
      Internal.delegate(self, :value, *methods)

      # @return [String] Returns a string representation of the counter.
      def inspect = "#<#{self.class.name} #{value.inspect}>"

      # @api private
      # @return [void]
      def pretty_print(pp) = pp.group(1, "#<#{self.class.name} ", ">") { pp.pp(value) }

      private

      def method_missing(...)              = value.public_send(...)
      def respond_to_missing?(method, ...) = value.respond_to?(method)
    end
  end
end
