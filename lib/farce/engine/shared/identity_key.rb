# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class IdentityKey
      BASIC_OBJECT_EQUAL_METHOD = BasicObject.instance_method(:equal?)
      BASIC_OBJECT_ID_METHOD = BasicObject.instance_method(:__id__)
      private_constant :BASIC_OBJECT_EQUAL_METHOD, :BASIC_OBJECT_ID_METHOD

      attr_reader :value

      def initialize(value) = @value = value
      def hash = BASIC_OBJECT_ID_METHOD.bind_call(value)
      def eql?(other) = other.is_a?(IdentityKey) && BASIC_OBJECT_EQUAL_METHOD.bind_call(value, other.value)

      alias == eql?
    end
  end
end
