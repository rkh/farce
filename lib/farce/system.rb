# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "etc"

module Farce
  # Information about the system running Farce.
  module System
    WINDOWS = Gem.win_platform?
    private_constant :WINDOWS

    # Whether the current operating system is Windows.
    # Safe to call from any Ractor.
    # @return [Boolean]
    def self.windows? = WINDOWS

    # Number of logical CPUs, optionally limited to a CPU type.
    # Returns nil when the platform cannot report the requested CPU type.
    # Safe to call from any Ractor.
    # @param type [nil, Symbol] nil for all CPUs, :performance, or :efficiency
    # @return [Integer, nil]
    # @raise [ArgumentError] if the CPU type is invalid
    def self.cpu_count(type = nil)
      case type
      when nil
        if defined?(Internal::Darwin) && Internal::Darwin.respond_to?(:cpu_count)
          Internal::Darwin.cpu_count
        else
          Etc.nprocessors
        end
      when :performance, :efficiency
        method = :"#{type}_cpu_count"
        Internal::Darwin.public_send(method) if defined?(Internal::Darwin) && Internal::Darwin.respond_to?(method)
      else
        raise ArgumentError, "invalid CPU type: #{type.inspect}"
      end
    end
  end
end
