# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal # :nodoc: all
    PoolSettings = Data.define(:min_size, :max_size, :max_inflight, :grow_after, :shrink_after, :generation)
  end
end
