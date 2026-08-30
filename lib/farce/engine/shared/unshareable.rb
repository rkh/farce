# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    module Unshareable
      def pin_to_current_ractor(object) = object
      def prevent_copyable(object)      = object
      def prevent_shareable(object)     = object
    end
  end
end
