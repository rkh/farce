# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class IdentityKey
      attr_reader :value

      def initialize(value) = @value = value
      def hash = value.object_id
      def eql?(other) = other.is_a?(IdentityKey) && value.equal?(other.value)

      alias == eql?
    end
  end
end
