# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/shared/unshared_weak_atom"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class WeakAtom < UnsharedWeakAtom
      private

      def validate_value(value)
        return if Farce::Ractor.shareable?(value)

        raise Ractor::IsolationError, "value must be Ractor-shareable"
      end
    end
  end
end
