# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A Ractor-shareable lease that moves one resource on checkout and checkin.
  #
  # @example Reusing an object across Ractors
  #   lease = Farce::Lease.new { [] }
  #   finished = Farce::Port.new
  #   Farce::Ractor.new(lease, finished) do |shared, result|
  #     size = shared.checkout do |items|
  #       items << :processed
  #       items.length
  #     end
  #     result << size
  #   end
  #
  #   finished.receive # => 1
  #   lease.checkout { |items| items.dup } # => [:processed]
  class Lease < Farce::Abstract::Lease
    include Shareable

    private

    def new_internal_lease(resource) = Internal::Lease.new(resource)
  end
end
