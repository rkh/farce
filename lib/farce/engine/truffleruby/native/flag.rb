# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Flag
      include FlagWaiting

      def initialize(value = false) # rubocop:disable Style/OptionalBooleanParameter
        raise "Flag is already initialized" if defined?(@reference)
        check_frozen!
        @signal = Signal.new
        @reference = TruffleRuby::AtomicReference.new(validate_boolean(value, "initial value"))
      end

      def change_signal = @signal

      def value = @reference.get

      def set # rubocop:disable Naming/PredicateMethod
        check_frozen!
        @reference.set(true)
        @signal.broadcast
        true
      end

      def unset # rubocop:disable Naming/PredicateMethod
        check_frozen!
        @reference.set(false)
        @signal.broadcast
        false
      end

      def store(value)
        check_frozen!
        value = validate_boolean(value, "value")
        @reference.set(value)
        @signal.broadcast
        value
      end

      def swap(value)
        check_frozen!
        value = validate_boolean(value, "value")
        @reference.get_and_set(value).tap { @signal.broadcast }
      end

      def compare_and_set(expected_value, replacement_value)
        check_frozen!
        expected_value    = validate_boolean(expected_value, "expected value")
        replacement_value = validate_boolean(replacement_value, "replacement value")
        @reference.compare_and_set(expected_value, replacement_value).tap { |changed| @signal.broadcast if changed }
      end

      def toggle
        check_frozen!
        loop do
          current = @reference.get
          replacement = !current
          if @reference.compare_and_set(current, replacement)
            @signal.broadcast
            return replacement
          end
        end
      end

      alias get value
      alias value= store

      private

      def check_frozen!
        raise FrozenError.new("can't modify frozen #{self.class}", receiver: self) if frozen?
      end

      def validate_boolean(value, name)
        return value if value.equal?(true) || value.equal?(false)
        raise ArgumentError, "#{name} must be true or false"
      end

      def initialize_copy(other)
        @signal = Signal.new
        @reference = TruffleRuby::AtomicReference.new(other.value)
      end
    end
  end
end
