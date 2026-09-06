# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal # :nodoc: all
    # Shared mode metadata and deletion probes. Reads and writes are specialized
    # in each public class to avoid forwarding overhead on the hot path.
    module ManagedQueue
      DeleteProbe = Data.define(:value, :compare_by_identity, :manager) do
        def ===(stored) = manager.same_value?(stored, value, identity: compare_by_identity)
      end
      private_constant :DeleteProbe

      def mode = @manager.mode

      private

      def delete_from_storage(priority, value, compare_by_identity:)
        comparison_mode = compare_by_identity ? :local : :copy
        value = @manager.wrap(value, mode: comparison_mode)
        @queue.delete_match(priority, DeleteProbe.new(value, compare_by_identity, @manager))
      end
    end
  end
end
