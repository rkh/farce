# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Local
    # A shareable pool with independent capacity and resources in each scope.
    #
    # @example Keeping separate pools in each Fiber
    #   pool = Farce::Local::LeasePool.new(scope: :fiber, max_size: 1) { [] }
    #   pool.checkout { |items| items << :parent }
    #
    #   Fiber.new { pool.checkout(&:dup) }.resume # => []
    #   pool.checkout(&:dup) # => [:parent]
    class LeasePool < Abstract::LeasePool
      include Scoped

      # Construct an empty pool in each scope.
      # @!macro scopes
      # @param scope [Symbol] the scope of the pool
      # @param max_size [Integer] the maximum number of resources in each scope
      # @yield builds a resource in the requesting scope
      # @yieldreturn [BasicObject] a new resource
      def initialize(max_size:, scope: :ractor, &factory)
        validate_configuration!(max_size, factory)
        @max_size = max_size
        @factory  = Ractor.shareable?(factory) ? factory : Ractor.shareable_proc(&factory)
        super(scope:, max_size:)
      end

      private

      def new_scoped_value(max_size:) = Internal::UnsharedLeasePool.new(max_size)
      def internal_pool = scoped_value
    end
  end
end
