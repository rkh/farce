# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal # :nodoc: all
    ParallelScheduler = Pool.new(max_size: System.cpu_count)
  end
end
