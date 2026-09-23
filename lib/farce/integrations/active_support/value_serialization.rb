# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# @!group ActiveSupport Integration
require "farce/integrations/active_support"

module Farce
  module Internal::ValueSerialization
    # @!macro active_support
    # Convert the current value using ActiveSupport's JSON conversion.
    # @overload as_json(options = nil)
    #   @param options [Hash, nil] Options forwarded to the current value's as_json.
    #   @return [Object, nil] The JSON-compatible value.
    def as_json(...) = value.as_json(...)
  end
end
