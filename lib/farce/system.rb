# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # Information about the system running Farce.
  module System
    WINDOWS = Gem.win_platform?
    private_constant :WINDOWS

    # Whether the current operating system is Windows.
    # Safe to call from any Ractor.
    # @return [Boolean]
    def self.windows? = WINDOWS
  end
end
