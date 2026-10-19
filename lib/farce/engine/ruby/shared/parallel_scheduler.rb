# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal # :nodoc: all
    config = FROZEN_CONFIG
    ParallelScheduler = Pool.new(
      min_size:     config.parallel_pool_min_size,
      max_size:     config.parallel_pool_max_size || System.cpu_count,
      max_inflight: config.parallel_pool_max_inflight,
      grow_after:   config.parallel_pool_grow_after,
      shrink_after: config.parallel_pool_shrink_after,
      capacity:     config.parallel_pool_capacity,
    )
  end
end
