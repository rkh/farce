# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract Common numeric interface and atomic operations for counters.
    # @note This is a module rather than a class so {Farce::Counter} can inherit
    #   directly from the native counter and avoid delegation overhead.
    module Counter
      include Value

      # @return [Integer] The initial value of the counter.
      attr_reader :initial

      # Reset the counter to its initial value.
      # @return [self] Returns self for chaining.
      def reset
        self.value = @initial
        self
      end

      # Increment the counter by one if its current value is below the limit.
      # The check and increment happen atomically.
      # @param [Numeric, String, #to_int] limit The upper bound, converted to an Integer.
      # @return [Boolean] true if the counter changed, otherwise false.
      def increment_if_below(limit) # rubocop:disable Naming/PredicateMethod
        limit   = Integer(limit)
        current = value

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
