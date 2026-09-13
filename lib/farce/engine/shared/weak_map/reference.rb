# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class UnsharedWeakMapReference
      def initialize(value) = @value = value
      def read              = [true, @value]
    end
    private_constant :UnsharedWeakMapReference

    # A weak value slot also supplies reverse key lookup for enumeration.
    class UnsharedWeakMapWeakReference
      def self.for(value)
        Internal.garbage_collectable?(value) ? new(value) : UnsharedWeakMapReference.new(value)
      end

      def initialize(value)
        @token        = Object.new
        @data         = ObjectSpace::WeakMap.new
        @data[@token] = value
      end

      def read
        value = @data[@token]
        [!value.nil?, value]
      end
    end
    private_constant :UnsharedWeakMapWeakReference
  end
end
