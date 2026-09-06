# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Unshared
    # A timer queue that stores and returns values directly.
    class TimerQueue < Abstract::TimerQueue
      include Unshareable
      include Internal::UnsharedQueueWaiting

      def mode = :local
    end
  end
end
