# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Strict
    # A FIFO queue that stores and returns values directly.
    class Queue < Abstract::Queue
      include Shareable

      def initialize(capacity: 1024)
        @queue = Internal::Queue.new(capacity:)
        super()
      end
    end
  end
end
