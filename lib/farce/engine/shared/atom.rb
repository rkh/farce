# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Atom
      def initialize(value = nil, compare_by_identity: false)
        @value               = value
        @compare_by_identity = compare_by_identity
        @mutex               = Mutex.new
      end

      attr_reader :value

      def compare_by_identity? = @compare_by_identity

      def compare_and_set(expected, new_value)
        @mutex.synchronize do
          return false unless match?(expected)
          @value = new_value
          true
        end
      end

      def store_if_absent
        @mutex.synchronize do
          return @value unless @value.nil?
          @value = yield
        end
      end

      def upsert(initial)
        @mutex.synchronize do
          return @value = initial if @value.nil?
          @value = yield(@value)
        end
      end

      def value=(new_value)
        @mutex.synchronize { @value = new_value }
      end

      private

      # def timed_synchronize(timeout)
      #   if
      # end

      def match?(expected)
        return @value == expected unless compare_by_identity?
        @value.equal?(expected)
      end
    end
  end
end
