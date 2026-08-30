# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # @api private
    # Rebindable implementation shared between JRuby and TruffleRuby engine support.
    def rebindable?(proc)
      return false unless proc.is_a?(Proc)
      proc.inspect !~ /^#<Proc:0x[0-9a-f]+\(&:.*\) \(lambda\)>$/
    end
  end
end
