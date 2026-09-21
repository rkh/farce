# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Lease pool storage that passes resource references within one Ractor.
    class UnsharedLeasePool < LeasePoolState
      include Freeze::Unfreezable

      private

      def initialize_storage
        @resource_lock = Mutex.new
        @resources     = {}
      end

      def store_resource(token, resource)
        @resource_lock.synchronize { @resources[token] = resource }
      end

      def take_resource(token)
        @resource_lock.synchronize { @resources.delete(token) }
      end

      alias return_resource store_resource

      def discard_resource(token)
        @resource_lock.synchronize { @resources.delete(token) }
      end
    end
  end
end
