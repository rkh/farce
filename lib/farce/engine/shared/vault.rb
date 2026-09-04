# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Vault
      def initialize          = @data = ObjectSpace::WeakKeyMap.new
      def move_in(key, value) = @data[key] = value
      def copy_in(key, value) = @data[key] = value.dup
      def move_out(key)       = @data.delete(key)
      def copy_out(key)       = @data[key].dup

      def same_value?(left, right, identity: false, right_stored: true)
        left  = @data[left]
        right = @data[right] if right_stored
        return BasicObject.instance_method(:equal?).bind_call(left, right) if identity

        !!(left == right)
      end

      def delete(key)
        @data.delete(key)
        nil
      end
    end
  end
end
