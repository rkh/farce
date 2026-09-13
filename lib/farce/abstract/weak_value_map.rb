# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract Common superclass for concurrent maps that retain values weakly.
    class WeakValueMap < ConcurrentMap
      def weak_values? = true
    end
  end
end
