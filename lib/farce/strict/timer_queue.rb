# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Strict
    # A timer queue that stores and returns values directly.
    class TimerQueue < Abstract::TimerQueue
      include Internal::StrictQueueValues unless Internal.native_ractors?
      include Shareable
    end
  end
end
