# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Allows preloading the scheduler constant without requiring fiber scheduler support.
    class FiberScheduler
      def self.new(...) = raise NotImplementedError, "TruffleRuby does not support fiber schedulers"
    end
  end
end
