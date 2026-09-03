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

      def delete(key)
        @data.delete(key)
        nil
      end
    end
  end
end
