# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract Common superclass for concurrent maps that retain keys weakly.
    class WeakKeyMap < ConcurrentMap
      def weak_keys? = true
    end
  end
end
