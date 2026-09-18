# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # Serialization of a container's current value.
    module ValueSerialization
      # @api private
      # Called by Psych for generating YAML.
      def encode_with(coder)
        coder["value"] = value
        coder
      end

      # @api private
      # Called by Psych when parsing YAML.
      def init_with(coder)
        options = coder.map.except("value").transform_keys(&:to_sym)
        initialize(coder["value"], **options)
      end

      # Serialize the current value as JSON.
      # @return [String]
      def to_json(...) = value.to_json(...)
    end
  end
end
