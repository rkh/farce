# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Unshared
    # A priority queue that stores and returns values directly.
    class PriorityQueue < Abstract::PriorityQueue
      include Unshareable
      include Internal::UnsharedQueueWaiting

      # @return [Symbol] always returns :local
      def mode = :local
    end
  end
end
