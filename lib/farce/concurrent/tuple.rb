# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Concurrent
    # A replacement for `Concurrent::Tuple` from `concurrent-ruby`.
    # @see https://ruby-concurrency.github.io/concurrent-ruby/Concurrent/Tuple.html
    class Tuple
      include Enumerable
      include Shareable::Delegated

      # @return [Integer] the size of the tuple
      attr_reader :size

      # @param size [Integer] the size of the tuple
      def initialize(size)
        @size  = Integer(size)
        @tuple = Vector.new(@size)
        super()
      end

      # Retrieves the value at the given index, or `nil` if the index is out of bounds.
      # @param index [Integer] the index of the value to retrieve
      # @return [BasicObject, nil] the value at the given index, or `nil` if out of bounds
      def get(index) = index.between?(0, @size - 1) ? @tuple[index] : nil
      alias volatile_get get

      # Sets the value at the given index, or does nothing if the index is out of bounds.
      # @param index [Integer] the index of the value to set
      # @param value [BasicObject] the value to set
      # @return [BasicObject, nil] the value set, or `nil` if out of bounds
      def set(index, value) = index.between?(0, @size - 1) ? @tuple[index] = value : nil
      alias volatile_set set

      # Atomically sets the value at the given index to `new_value` if the current value is equal to `old_value`.
      # @param index [Integer] the index of the value to set
      # @param old_value [BasicObject] the expected current value
      # @param new_value [BasicObject] the new value to set
      # @return [Boolean] `true` if the value was set, `false` otherwise
      def compare_and_set(index, old_value, new_value)
        return false unless index.between?(0, @size - 1)
        @tuple.compare_and_set(index, old_value, new_value)
      end
      alias cas compare_and_set

      # Iterates over each element in the tuple.
      # @yieldparam value [BasicObject] the value of each element
      # @return [Enumerator, self] if no block is given, self otherwise
      def each(&)
        return enum_for(:each) unless block_given?
        @tuple.each(&)
        self
      end

      # @api private
      def marshal_dump
        [1, @tuple.to_a.map { Internal::MarshalSupport.value(it) }, frozen?]
      end

      # @api private
      def marshal_load(data)
        entries, frozen = Internal::MarshalSupport.payload(data, 2)
        initialize(entries.length)
        entries.each_with_index do |entry, index|
          @tuple[index] = Internal::MarshalSupport.restore_value(entry)
        end
        Internal::MarshalSupport.freeze(self, frozen)
      end

      private def freeze_backend = @tuple
    end
  end
end
