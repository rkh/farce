# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract Common superclass for concurrent maps that retain keys and values weakly.
    class WeakMap < ConcurrentMap
      def weak_keys?   = true
      def weak_values? = true
    end
  end
end
