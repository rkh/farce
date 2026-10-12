# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal # :nodoc: all
    # A worker coordinator pinned to its pool's Ractor.
    class UnsharedPoolWorker < PoolWorker
      include Farce::Unshareable

      private def publish_shareable = pin_unshareable
    end
  end
end
