# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# @!group ActiveSupport Integration
require "farce/integrations/active_support"

module Farce
  module Clock
    # @!macro active_support
    # Treat ActiveSupport durations as relative offsets.
    def self.parse(value)
      return offset(value) if ActiveSupport::Duration === value
      super
    end
  end
end
