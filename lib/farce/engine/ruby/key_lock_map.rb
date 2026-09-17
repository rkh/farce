# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/unshareable"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class UnsharedKeyLockMap
      include Farce::Unshareable
    end

    class KeyLockMap
      def self.new(registry_class:, **comparison_options)
        return super unless equal?(KeyLockMap)

        if registry_class.equal?(Farce::Unshared::Map)
          UnsharedKeyLockMap.new(**comparison_options)
        elsif registry_class.equal?(Farce::Strict::Map) || registry_class.equal?(Farce::Map)
          SharedKeyLockMap.new(**comparison_options)
        else
          super
        end
      end
    end
  end
end
