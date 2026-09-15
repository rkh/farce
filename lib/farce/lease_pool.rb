# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A Ractor-shareable pool that moves resources on checkout and checkin.
  #
  # @example Reusing an object across Ractors
  #   pool = Farce::LeasePool.new(max_size: 2) { [] }
  #   result = Farce::Ractor.new(pool) do |shared|
  #     shared.checkout do |items|
  #       items << :worker
  #       items.length
  #     end
  #   end.value
  #
  #   result # => 1
  class LeasePool < Farce::Abstract::LeasePool
    include Shareable

    private

    def prepare_factory(factory)
      Ractor.shareable?(factory) ? factory : Ractor.shareable_proc(&factory)
    end

    def new_internal_pool(max_size) = Internal::LeasePool.new(max_size)
  end
end
