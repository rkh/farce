# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @return [Scheduler] the scheduler used to schedule tasks on the main ractor
  MainScheduler = Scheduler.create(Thread)
end
