# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Extension point for integrations that serialize a container's current value.
    # @api private
    module ValueSerialization
    end
  end
end
