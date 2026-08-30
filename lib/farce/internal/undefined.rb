# frozen_string_literal: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Undefined < BasicObject
      define_method(:freeze,  ::Object.instance_method(:freeze))
      define_method(:frozen?, ::Object.instance_method(:frozen?))

      def initialize(inspect)
        @inspect = inspect
        Ractor.make_shareable(self) if defined?(Ractor)
        freeze
      end

      attr_reader :inspect

      def nil? = false
      alias === equal?
    end
  end
end
