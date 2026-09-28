# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal
    # Mixin to have some BasicObject methods still trigger method_missing
    # Notable exceptions: #equal?, #__send__, #__id__
    module Delegation
      def ==(other)          = method_missing(:==, other)
      def !                  = method_missing(:!)
      def instance_eval(...) = method_missing(:instance_eval, ...)
      def instance_exec(...) = method_missing(:instance_exec, ...)

      def !=(other)
        method_missing(:!=, other)
      end
    end
  end
end
