# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # When including Farce in a class or module, this module is included instead
    # This avoids pulling in private constants, like {Farce::Internal} or `UNDEFINED`.
    module Mixin
      # This will trigger all autoloads, but any other approach would be complex and fragile.
      Farce.constants(false).each { const_set(it, Farce.const_get(it)) unless it =~ /\A[A-Z_]+\Z|\ATest/ }

      def self.included(base)
        return unless base.const_defined?(:Ractor, false) && ractor = base.const_get(:Ractor, false)
        ractor.const_set(:Port, Farce::Port) unless ractor.const_defined?(:Port, false)
      end
    end
  end
end
